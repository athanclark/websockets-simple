{-# LANGUAGE
    DeriveGeneric
  , DeriveDataTypeable
  , RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  , FlexibleContexts
  , InstanceSigs
  #-}

module Network.WebSockets.Simple
  ( -- * Types
    WebSocketsApp (..), WebSocketsAppParams (..)
  , Network.WebSockets.ConnectionException (..), CloseOrigin (..), WebSocketsSimpleError (..)
  , -- * Running
    toClientAppT
  , toServerAppT
  , -- * Utilities
    expBackoffStrategy
  , hoistWebSocketsApp
  ) where

import Network.WebSockets (DataMessage (..), sendTextData, sendClose, receiveDataMessage, acceptRequest, ConnectionException (..))
import Network.Wai.Trans (ServerAppT, ClientAppT)
import Data.Profunctor (Profunctor (..))
import Data.Aeson (ToJSON (..), FromJSON (..))
import qualified Data.Aeson as Aeson
import Data.ByteString.Lazy (ByteString)

import Control.Monad (forever)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Catch (Exception, throwM, MonadThrow, catch, MonadCatch)
import Control.Monad.Trans.Control (MonadBaseControl (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO, writeTVar)

import GHC.Generics (Generic)
import Data.Typeable (Typeable)



data WebSocketsAppParams m send = WebSocketsAppParams
  { send  :: send -> m ()
  , close :: m ()
  } deriving (Generic, Typeable)


data WebSocketsApp m receive send = WebSocketsApp
  { onOpen    :: WebSocketsAppParams m send -> m ()
  , onReceive :: WebSocketsAppParams m send -> receive -> m ()
  , onClose   :: CloseOrigin -> ConnectionException -> m () -- ^ Should be re-entrant; this exception is caught in all uses of 'send', even if used in a dead 'Network.WebSockets.Connection' in a lingering thread.
  } deriving (Generic, Typeable)

data CloseOrigin
  = ClosedOnSend
  | ClosedOnClose
  | ClosedOnReceive


instance Profunctor (WebSocketsApp m) where
  dimap :: forall a b c d. (a -> b) -> (c -> d) -> WebSocketsApp m b c -> WebSocketsApp m a d
  dimap receiveF sendF WebSocketsApp{onOpen,onReceive,onClose} = WebSocketsApp
    { onOpen = \params -> onOpen (getParams params)
    , onReceive = \params r -> onReceive (getParams params) (receiveF r)
    , onClose = \o e -> onClose o e
    }
    where
      getParams :: WebSocketsAppParams m d -> WebSocketsAppParams m c
      getParams WebSocketsAppParams{send,close} = WebSocketsAppParams{send = send . sendF,close}


hoistWebSocketsApp :: (forall a. m a -> n a)
                   -> (forall a. n a -> m a)
                   -> WebSocketsApp m receive send
                   -> WebSocketsApp n receive send
hoistWebSocketsApp f coF WebSocketsApp{onOpen,onReceive,onClose} = WebSocketsApp
  { onOpen = \WebSocketsAppParams{send,close} -> f (onOpen WebSocketsAppParams{send = coF . send, close = coF close})
  , onReceive = \WebSocketsAppParams{send,close} r -> f (onReceive WebSocketsAppParams{send = coF . send, close = coF close} r)
  , onClose = \o e -> f (onClose o e)
  }



instance Applicative m => Monoid (WebSocketsApp m receive send) where
  mempty = WebSocketsApp
    { onOpen = \_ -> pure ()
    , onReceive = \_ _ -> pure ()
    , onClose = \_ _ -> pure ()
    }
  mappend x y = WebSocketsApp
    { onOpen = \params -> onOpen x params *> onOpen y params
    , onReceive = \params r -> onReceive x params r *> onReceive y params r
    , onClose = \o mE -> onClose x o mE *> onClose y o mE
    }


-- | This can throw a 'WebSocketSimpleError' to the main thread via 'Control.Concurrent.Async.link' when json parsing fails.
toClientAppT :: forall send receive m
              . ( ToJSON send
                , FromJSON receive
                , MonadIO m
                , MonadBaseControl IO m
                , MonadThrow m
                , MonadCatch m
                )
             => WebSocketsApp m receive send
             -> ClientAppT m () -- WebSocketsAppThreads
toClientAppT WebSocketsApp{onOpen,onReceive,onClose} conn = do
  let send :: send -> m ()
      send x = liftIO (sendTextData conn (Aeson.encode x)) `catch` (onClose ClosedOnSend)

      close :: m ()
      close = liftIO (sendClose conn (Aeson.encode "requesting close")) `catch` (onClose ClosedOnClose)

      params :: WebSocketsAppParams m send
      params = WebSocketsAppParams{send,close}

  onOpen params

  liftBaseWith $ \runInBase ->
    let go' = forever $ do
          data' <- receiveDataMessage conn
          let data'' = case data' of
                        Text xs _ -> xs
                        Binary xs -> xs
          case Aeson.decode data'' of
            Nothing -> throwM (JSONParseError data'')
            Just received -> runInBase (onReceive params received)
    in  go' `catch` (\e -> () <$ (runInBase (onClose ClosedOnReceive e)))



toServerAppT :: ( ToJSON send
                , FromJSON receive
                , MonadIO m
                , MonadBaseControl IO m
                , MonadThrow m
                , MonadCatch m
                ) => WebSocketsApp m receive send -> ServerAppT m
toServerAppT wsApp pending =
  liftIO (acceptRequest pending) >>= toClientAppT wsApp



-- | A simple backoff strategy, which (per second), will increasingly delay at @2^soFar@, until @soFar >= 5minutes@, where it will then routinely poll every
--   5 minutes.
expBackoffStrategy :: forall m a
                    . ( MonadIO m
                      )
                   => m a -- ^ Action to call, like pinging a scoped channel to trigger the reconnect
                   -> m (ConnectionException -> m a)
expBackoffStrategy action = do
  soFarVar <- liftIO $ newTVarIO (0 :: Int)

  let second = 1000000

  pure $ \_ -> do
    liftIO $ do
      soFar <- readTVarIO soFarVar
      let delay
            | soFar >= 5 * 60 = 5 * 60
            | otherwise       = 2 ^ soFar
      atomically $ writeTVar soFarVar (soFar + delay)
      threadDelay (delay * second)
    action



data WebSocketsSimpleError
  = JSONParseError ByteString
  deriving (Generic, Eq, Show)

instance Exception WebSocketsSimpleError

