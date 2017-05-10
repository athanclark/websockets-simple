{-# LANGUAGE
    DeriveGeneric
  , DeriveDataTypeable
  , RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  , FlexibleContexts
  #-}

module Network.WebSockets.Simple where

import Network.WebSockets (DataMessage (..), sendTextData, sendClose, receiveDataMessage, acceptRequest, ConnectionException (CloseRequest))
import Network.Wai.Trans (ServerAppT, ClientAppT)
import Data.Aeson (ToJSON (..), FromJSON (..))
import qualified Data.Aeson as Aeson
import Data.ByteString.Lazy (ByteString)
import Data.IORef (newIORef, writeIORef, readIORef)
import Data.Word (Word16)

import Control.Monad (void, forever)
import Control.Monad.Catch (Exception, throwM, MonadThrow, catch, MonadCatch)
import Control.Monad.Trans.Control (MonadBaseControl (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan (TChan, newTChanIO, writeTChan)

import GHC.Generics (Generic)
import Data.Typeable (Typeable)



data WebSocketsAppParams send m = WebSocketsAppParams
  { send  :: send -> m ()
  , close :: m ()
  } deriving (Generic, Typeable)


data WebSocketsApp send receive m = WebSocketsApp
  { onOpen    :: WebSocketsAppParams send m -> m ()
  , onReceive :: WebSocketsAppParams send m -> receive -> m ()
  , onClose   :: Maybe (Word16, ByteString) -> m () -- ^ Either was a clean close, with 'Network.WebSockets.CloseRequest' params, or was unclean.
                                                    --   Note that to implement backoff strategies, you should catch your 'Network.WebSockets.ConnectionException'
                                                    --   /outside/ this simple app, and only after you've 'Network.WebSockets.runClient' or server, because the
                                                    --   'Network.WebSockets.Connection' will be different.
  } deriving (Generic, Typeable)


hoistWebSocketsApp :: (forall a. m a -> n a)
                   -> (forall a. n a -> m a)
                   -> WebSocketsApp send receive m
                   -> WebSocketsApp send receive n
hoistWebSocketsApp f coF WebSocketsApp{onOpen,onReceive,onClose} = WebSocketsApp
  { onOpen = \WebSocketsAppParams{send,close} -> f $ onOpen WebSocketsAppParams{send = coF . send, close = coF close}
  , onReceive = \WebSocketsAppParams{send,close} r -> f $ onReceive WebSocketsAppParams{send = coF . send, close = coF close} r
  , onClose = f . onClose
  }


-- | This can throw a 'WebSocketSimpleError' when json parsing fails. However, do note:
--   the 'onOpen' is called once, but is still forked when called. Likewise, the 'onReceive'
--   function is called /every time/ a (parsable) response is received from the other party,
--   and is forked on every invocation.
toClientAppT :: forall send receive m
              . ( ToJSON send
                , FromJSON receive
                , MonadBaseControl IO m
                , MonadThrow m
                , MonadCatch m
                )
             => WebSocketsApp send receive m
             -> ClientAppT m (Maybe WebSocketsAppThreads)
toClientAppT WebSocketsApp{onOpen,onReceive,onClose} conn = do
  let go = do
        let send :: send -> m ()
            send x = liftBaseWith $ \_ -> sendTextData conn (Aeson.encode x)

            close :: m ()
            close = liftBaseWith $ \_ -> sendClose conn (Aeson.encode "requesting close")

            params :: WebSocketsAppParams send m
            params = WebSocketsAppParams{send,close}

        onOpenThread <- liftBaseWith $ \runToBase ->
          async $ void $ runToBase $ onOpen params

        onReceiveThreads <- liftBaseWith $ \_ -> newTChanIO

        void $ forever $ do
          data' <- liftBaseWith $ \_ -> receiveDataMessage conn
          let data'' = case data' of
                        Text xs _ -> xs
                        Binary xs -> xs
          case Aeson.decode data'' of
            Nothing -> throwM (JSONParseError data'')
            Just received -> liftBaseWith $ \runToBase -> do
              thread <- async $ void $ runToBase $ onReceive params received
              atomically $ writeTChan onReceiveThreads thread

        pure $ Just WebSocketsAppThreads
          { onOpenThread
          , onReceiveThreads
          }

      onDisconnect :: ConnectionException -> m (Maybe WebSocketsAppThreads)
      onDisconnect err = do
        case err of
          CloseRequest code reason -> onClose (Just (code,reason))
          _                        -> onClose Nothing
        pure Nothing

  go `catch` onDisconnect



toClientAppT' :: (ToJSON send, FromJSON receive, MonadBaseControl IO m, MonadThrow m, MonadCatch m) => WebSocketsApp send receive m -> ClientAppT m ()
toClientAppT' wsApp conn = void (toClientAppT wsApp conn)


toServerAppT :: (ToJSON send, FromJSON receive, MonadBaseControl IO m, MonadThrow m, MonadCatch m) => WebSocketsApp send receive m -> ServerAppT m
toServerAppT wsApp pending = do
  conn <- liftBaseWith $ \_ -> acceptRequest pending
  toClientAppT' wsApp conn



-- | A simple backoff strategy, which (per second), will increasingly delay at @2^soFar@, until @soFar >= 5minutes@, where it will then routinely poll every
--   5 minutes.
expBackoffStrategy :: forall m a
                    . ( MonadBaseControl IO m
                      , MonadCatch m
                      )
                   => m a -- ^ The run app
                   -> m a
expBackoffStrategy app = do
  soFarVar <- liftBaseWith $ \_ -> newIORef (0 :: Int)

  let second = 1000000

  let go = app `catch` backoffStrat

      backoffStrat :: ConnectionException -> m a
      backoffStrat _ = do
        liftBaseWith $ \_ -> do
          soFar <- readIORef soFarVar
          let delay
                | soFar >= 5 * 60 = 5 * 60
                | otherwise       = 2 ^ soFar
          writeIORef soFarVar (soFar + delay)
          threadDelay (delay * second)
        go

  go



data WebSocketSimpleError
  = JSONParseError ByteString
  deriving (Generic, Eq, Show)

instance Exception WebSocketSimpleError


data WebSocketsAppThreads = WebSocketsAppThreads
  { onOpenThread     :: Async ()
  , onReceiveThreads :: TChan (Async ())
  }
