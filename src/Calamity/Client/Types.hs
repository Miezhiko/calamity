-- | Types for the client
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Calamity.Client.Types
    ( Client(..)
    , Cache(..)
    , BotC
    , EventC
    , Event
    , EHType
    , EventHandlers(..)
    , EventHandler(..)
    , Handlers
    , runBot
    , runEvent
    , runHandlers
    , getCache
    , syncCache
    , react ) where

import           Calamity.Gateway.DispatchEvents
import           Calamity.Gateway.Shard
import           Calamity.HTTP.Internal.Types
import           Calamity.Types.General
import           Calamity.Types.MessageStore
import qualified Calamity.Types.RefCountedSnowflakeMap as RSM
import           Calamity.Types.Snowflake
import qualified Calamity.Types.SnowflakeMap           as SM
import           Calamity.Types.UnixTimestamp

import           Control.Concurrent.STM.TQueue
import           Control.Concurrent.STM.TVar

import           Data.Default
import qualified Data.HashSet                          as LS
import           Data.String                           ( String )
import           Data.Time
import qualified Data.TypeRepMap                       as TM
import           Data.TypeRepMap                       ( TypeRepMap, WrapTypeable(..) )

import qualified Df1

import           DiPolysemy

import           GHC.Exts                              ( fromList )
import qualified GHC.TypeLits                          as TL

import           Polysemy                              ( Sem )
import qualified Polysemy                              as P
-- import qualified Polysemy.Embed                        as P
import qualified Polysemy.Error                        as P
import qualified Polysemy.Output                       as P
import qualified Polysemy.Reader                       as P
import qualified Polysemy.State                        as P

import qualified StmContainers.Set                     as TS

import qualified Streamly                              as S


data Cache = Cache
  { user              :: Maybe User
  , guilds            :: SM.SnowflakeMap Guild
  , dms               :: SM.SnowflakeMap DMChannel
  , channels          :: SM.SnowflakeMap Channel
  , users             :: RSM.RefCountedSnowflakeMap User
  , unavailableGuilds :: LS.HashSet (Snowflake Guild)
  , messages          :: MessageStore
  }
  deriving ( Generic, Show )

data Client = Client
  { shards        :: TVar [(Shard, Async ())] -- TODO: migrate this to a set of Shard (make Shard hash to it's shardThread)
  , numShards     :: MVar Int
  , token         :: Token
  , rlState       :: RateLimitState
  , eventStream   :: S.Serial DispatchData
  , eventQueue    :: TQueue DispatchData -- ^ for shards to take
  , cache         :: TVar Cache
  , activeTasks   :: TS.Set (Async ()) -- ^ events currently being handled
  , eventHandlers :: EventHandlers
  }
  deriving ( Generic )

type BotC r = (LogC r, P.Members '[P.Reader Client, P.Embed IO] r)

runBot :: Client -> Sem (P.Reader Client ': r) a -> Sem r a
runBot = P.runReader


data EventState m a where
  GetCache :: EventState m Cache
  SyncCache :: EventState m ()

reinterpretEventStateToState :: P.Members '[P.Embed IO, P.Reader Client] r => Sem (EventState ': r) a -> Sem (P.State Cache ': r) a
reinterpretEventStateToState =
  P.reinterpret $ \case
    GetCache -> P.get
    SyncCache -> do
      client <- P.ask
      cache <- P.embed . readTVarIO . cache $ client
      P.put cache

type EventC r a = (BotC r, P.Members '[P.Error Text, EventState] r)
type Event a = Sem '[P.Error Text, EventState, P.Reader Client, LogEff, P.Embed IO] a

runEvent :: BotC r => Cache -> Sem (P.Error Text ': EventState ': r) a -> Sem r ()
runEvent c eff = do
  r <- P.evalState c
        . reinterpretEventStateToState
        . P.runError $ eff
  case r of
    Left e ->
      DiPolysemy.error e
    _ -> pure ()

data Handlers m a where
  React :: EventHandlers -> Handlers m ()

runHandlers :: Sem (Handlers ': r) () -> Sem r EventHandlers
runHandlers = do
  (fst <$>) . P.runOutputMonoid identity . reinterp

  where reinterp :: Sem (Handlers ': r) a -> Sem (P.Output EventHandlers ': r) a
        reinterp = P.reinterpret $ \case
          React h -> P.output h

type family EHType d where
  EHType "ready"                    = ReadyData                          -> Event ()
  EHType "channelcreate"            = Channel                            -> Event ()
  EHType "channelupdate"            = Channel -> Channel                 -> Event ()
  EHType "channeldelete"            = Channel                            -> Event ()
  EHType "channelpinsupdate"        = Channel -> Maybe UTCTime           -> Event ()
  EHType "guildcreate"              = Guild -> Bool                      -> Event ()
  EHType "guildupdate"              = Guild -> Guild                     -> Event ()
  EHType "guilddelete"              = Guild -> Bool                      -> Event ()
  EHType "guildbanadd"              = Guild -> User                      -> Event ()
  EHType "guildbanremove"           = Guild -> User                      -> Event ()
  EHType "guildemojisupdate"        = Guild -> [Emoji]                   -> Event ()
  EHType "guildintegrationsupdate"  = Guild                              -> Event ()
  EHType "guildmemberadd"           = Member                             -> Event ()
  EHType "guildmemberremove"        = Member                             -> Event ()
  EHType "guildmemberupdate"        = Member -> Member                   -> Event ()
  EHType "guildmemberschunk"        = Guild -> [Member]                  -> Event ()
  EHType "guildrolecreate"          = Guild -> Role                      -> Event ()
  EHType "guildroleupdate"          = Guild -> Role -> Role              -> Event ()
  EHType "guildroledelete"          = Guild -> Role                      -> Event ()
  EHType "messagecreate"            = Message                            -> Event ()
  EHType "messageupdate"            = Message -> Message                 -> Event ()
  EHType "messagedelete"            = Message                            -> Event ()
  EHType "messagedeletebulk"        = [Message]                          -> Event ()
  EHType "messagereactionadd"       = Message -> Reaction                -> Event ()
  EHType "messagereactionremove"    = Message -> Reaction                -> Event ()
  EHType "messagereactionremoveall" = Message                            -> Event ()
  EHType "typingstart"              = Channel -> Member -> UnixTimestamp -> Event ()
  EHType "userupdate"               = User -> User                       -> Event ()
  EHType _ = TL.TypeError ('TL.Text "Unknown event name")
  -- EHType "voicestateupdate"         = VoiceStateUpdateData -> EventM ()
  -- EHType "voiceserverupdate"        = VoiceServerUpdateData -> EventM ()
  -- EHType "webhooksupdate"           = WebhooksUpdateData -> EventM ()

newtype EventHandlers = EventHandlers (TypeRepMap EventHandler)

newtype EventHandler d = EH
  { unwrapEventHandler :: [EHType d]
  }
  deriving newtype ( Semigroup, Monoid )

instance Default EventHandlers where
  def = EventHandlers $ fromList [ WrapTypeable $ EH @"ready" []
                                 , WrapTypeable $ EH @"channelcreate" []
                                 , WrapTypeable $ EH @"channelupdate" []
                                 , WrapTypeable $ EH @"channeldelete" []
                                 , WrapTypeable $ EH @"channelpinsupdate" []
                                 , WrapTypeable $ EH @"guildcreate" []
                                 , WrapTypeable $ EH @"guildupdate" []
                                 , WrapTypeable $ EH @"guilddelete" []
                                 , WrapTypeable $ EH @"guildbanadd" []
                                 , WrapTypeable $ EH @"guildbanremove" []
                                 , WrapTypeable $ EH @"guildemojisupdate" []
                                 , WrapTypeable $ EH @"guildintegrationsupdate" []
                                 , WrapTypeable $ EH @"guildmemberadd" []
                                 , WrapTypeable $ EH @"guildmemberremove" []
                                 , WrapTypeable $ EH @"guildmemberupdate" []
                                 , WrapTypeable $ EH @"guildrolecreate" []
                                 , WrapTypeable $ EH @"guildroleupdate" []
                                 , WrapTypeable $ EH @"guildroledelete" []
                                 , WrapTypeable $ EH @"messagecreate" []
                                 , WrapTypeable $ EH @"messageupdate" []
                                 , WrapTypeable $ EH @"messagedelete" []
                                 , WrapTypeable $ EH @"messagedeletebulk" []
                                 , WrapTypeable $ EH @"messagereactionadd" []
                                 , WrapTypeable $ EH @"messagereactionremove" []
                                 , WrapTypeable $ EH @"messagereactionremoveall" []
                                 , WrapTypeable $ EH @"typingstart" []
                                 , WrapTypeable $ EH @"userupdate" []
                                 -- , WrapTypeable $ EH @"voicestateupdate" []
                                 -- , WrapTypeable $ EH @"voiceserverupdate" []
                                 -- , WrapTypeable $ EH @"webhooksupdate" []
                                 ]

instance Semigroup EventHandlers where
  (EventHandlers a) <> (EventHandlers b) = EventHandlers $ TM.unionWith (<>) a b

instance Monoid EventHandlers where
  mempty = def


P.makeSem ''EventState
P.makeSem ''Handlers
