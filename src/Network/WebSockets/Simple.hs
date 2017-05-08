{-# LANGUAGE
    DeriveGeneric
  , DeriveDataTypeable
  , RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  , FlexibleContexts
  #-}

module Network.WebSockets.Simple where

import Network.WebSockets (DataMessage (..), sendTextData, receiveDataMessage, acceptRequest, ConnectionException)
import Network.Wai.Trans (ServerAppT, ClientAppT)
import Data.Aeson (ToJSON (..), FromJSON (..))
import qualified Data.Aeson as Aeson
import Data.ByteString.Lazy (ByteString)
import Data.IORef (newIORef, writeIORef, readIORef)

import Control.Monad (void, forever)
import Control.Monad.Catch (Exception, throwM, MonadThrow, catch, MonadCatch)
import Control.Monad.Trans.Control (MonadBaseControl (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan (TChan, newTChanIO, writeTChan)

import GHC.Generics (Generic)
import Data.Typeable (Typeable)


data WebSocketsApp send receive m = WebSocketsApp
  { onOpen    :: (send -> m ()) -> m ()
  , onReceive :: (send -> m ()) -> receive -> m ()
  } deriving (Generic, Typeable)


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
toClientAppT WebSocketsApp{onOpen,onReceive} conn = do
  toWaitVar <- liftBaseWith $ \_ -> newIORef (0 :: Int)
  let go =
        let go' = do
              liftBaseWith $ \_ -> writeIORef toWaitVar 0
              let send :: send -> m ()
                  send x = liftBaseWith $ \_ -> sendTextData conn (Aeson.encode x)

              onOpenThread <- liftBaseWith $ \runToBase ->
                async $ void $ runToBase $ onOpen send

              onReceiveThreads <- liftBaseWith $ \_ -> newTChanIO

              forever $ do
                data' <- liftBaseWith $ \_ -> receiveDataMessage conn
                let data'' = case data' of
                              Text xs _ -> xs
                              Binary xs -> xs
                case Aeson.decode data'' of
                  Nothing -> throwM (JSONParseError data'')
                  Just received -> liftBaseWith $ \runToBase -> do
                    thread <- async $ void $ runToBase $ onReceive send received
                    atomically $ writeTChan onReceiveThreads thread

              pure $ Just WebSocketsAppThreads
                { onOpenThread
                , onReceiveThreads
                }

            onDisconnect :: ConnectionException -> m (Maybe WebSocketsAppThreads)
            onDisconnect _ = do
              liftBaseWith $ \_ -> do
                toWait <- readIORef toWaitVar
                writeIORef toWaitVar (toWait+1)
                let second = 1000000
                threadDelay $ second * (2^toWait)
              go
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
