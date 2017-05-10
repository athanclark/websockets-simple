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
  , onClose   :: Maybe (Word16, ByteString) -> m (Int -> Maybe Int) -- ^ Either was a clean close, with 'Network.WebSockets.CloseRequest' params, or was unclean.
                                                                    --   Returns a function which defines the backoff strategy - takes in total time (microseconds)
                                                                    --   elapsed during connection closed, and may return a new delay before attempting to connect again;
                                                                    --   if none, then it won't try again.
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
  soFarVar <- liftBaseWith $ \_ -> newIORef (0 :: Int)
  let go =
        let go' = do
              liftBaseWith $ \_ -> writeIORef soFarVar 0
              let send :: send -> m ()
                  send x = liftBaseWith $ \_ -> sendTextData conn (Aeson.encode x)

                  close :: m ()
                  close = liftBaseWith $ \_ -> sendClose conn (Aeson.encode "requesting close")

                  params :: WebSocketsAppParams send m
                  params = WebSocketsAppParams{send,close}

              onOpenThread <- liftBaseWith $ \runToBase ->
                async $ void $ runToBase $ onOpen params

              onReceiveThreads <- liftBaseWith $ \_ -> newTChanIO

              forever $ do
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
              backoffStrategy <- case err of
                CloseRequest code reason -> onClose (Just (code,reason))
                _                        -> onClose Nothing
              canGo <- liftBaseWith $ \_ -> do
                soFar <- readIORef soFarVar
                case backoffStrategy soFar of
                  Nothing -> pure False -- give up
                  Just delay -> do
                    writeIORef soFarVar (soFar + delay)
                    threadDelay delay
                    pure True
              if canGo then go else pure Nothing

        in  go' `catch` onDisconnect
  go



toClientAppT' :: (ToJSON send, FromJSON receive, MonadBaseControl IO m, MonadThrow m, MonadCatch m) => WebSocketsApp send receive m -> ClientAppT m ()
toClientAppT' wsApp conn = void (toClientAppT wsApp conn)


toServerAppT :: (ToJSON send, FromJSON receive, MonadBaseControl IO m, MonadThrow m, MonadCatch m) => WebSocketsApp send receive m -> ServerAppT m
toServerAppT wsApp pending = do
  conn <- liftBaseWith $ \_ -> acceptRequest pending
  toClientAppT' wsApp conn



data WebSocketSimpleError
  = JSONParseError ByteString
  deriving (Generic, Eq, Show)

instance Exception WebSocketSimpleError


data WebSocketsAppThreads = WebSocketsAppThreads
  { onOpenThread     :: Async ()
  , onReceiveThreads :: TChan (Async ())
  }
