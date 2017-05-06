{-# LANGUAGE
    DeriveGeneric
  , DeriveDataTypeable
  , RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  , FlexibleContexts
  #-}

module Network.WebSockets.Simple where

import Network.WebSockets (DataMessage (..), sendTextData, receiveDataMessage)
import Network.Wai.Trans (ServerAppT, ClientAppT)
import Data.Aeson (ToJSON (..), FromJSON (..))
import qualified Data.Aeson as Aeson
import Data.ByteString.Lazy (ByteString)

import Control.Monad (void, forever)
import Control.Monad.Catch (Exception, throwM, MonadThrow)
import Control.Monad.Trans.Control (MonadBaseControl (..))
import Control.Concurrent.Async (Async, async)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan (TChan, newTChanIO, writeTChan)

import GHC.Generics (Generic)
import Data.Typeable (Typeable)


data WebSocketsApp send receive m = WebSocketsApp
  { onOpen :: (send -> m ()) -> m ()
  , onReceive :: (send -> m ()) -> receive -> m ()
  } deriving (Generic, Typeable)


data WebSocketSimpleError
  = JSONParseError ByteString
  deriving (Generic, Eq, Show)

instance Exception WebSocketSimpleError


data WebSocketsAppThreads = WebSocketsAppThreads
  { onOpenThread     :: Async ()
  , onReceiveThreads :: TChan (Async ())
  }


toClientAppT :: forall send receive m
              . ( ToJSON send
                , FromJSON receive
                , MonadBaseControl IO m
                , MonadThrow m
                )
             => WebSocketsApp send receive m
             -> ClientAppT m WebSocketsAppThreads
toClientAppT WebSocketsApp{onOpen,onReceive} = \conn -> do
  let send :: send -> m ()
      send x = liftBaseWith $ \_ -> sendTextData conn (Aeson.encode x)

  onOpenThread <- liftBaseWith $ \runToBase ->
    async $ void $ runToBase $ onOpen send

  onReceiveThreads <- liftBaseWith $ \_ -> newTChanIO

  forever $ do
    data' <- liftBaseWith $ \_ -> receiveDataMessage conn
    let data'' = case data' of
                   Text xs -> xs
                   Binary xs -> xs
    case Aeson.decode data'' of
      Nothing -> throwM (JSONParseError data'')
      Just received -> liftBaseWith $ \runToBase -> do
        thread <- async $ void $ runToBase $ onReceive send received
        atomically $ writeTChan onReceiveThreads thread

  pure WebSocketsAppThreads
    { onOpenThread
    , onReceiveThreads
    }



toClientAppT' :: (ToJSON send, FromJSON receive, MonadBaseControl IO m, MonadThrow m) => WebSocketsApp send receive m -> ClientAppT m ()
toClientAppT' wsApp conn = void (toClientAppT wsApp conn)
