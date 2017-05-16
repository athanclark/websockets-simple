{-# LANGUAGE
    RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  , FlexibleContexts
  #-}

module Test.WebSockets.Simple where


import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..))
import Control.Monad (forever, void)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Trans.Control (MonadBaseControl (..))
import Control.Concurrent.Async (Async, async)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan (TChan, newTChan, writeTChan, readTChan)



-- | Runs two 'WebSocketsApp's together in a forged channel.
runConnected :: forall send receive m
              . ( MonadIO m
                , MonadBaseControl IO m
                )
             => WebSocketsApp send receive m
             -> WebSocketsApp receive send m
             -> m (Async (), Async (), TChan send, TChan receive)
runConnected sendsSreceivesR sendsRreceivesS = do
  (sendChan, receiveChan) <- liftIO $ atomically $ (,) <$> newTChan <*> newTChan

  let sendToSend :: send -> m ()
      sendToSend s = liftIO $ atomically $ writeTChan sendChan s

      sendToReceive :: receive -> m ()
      sendToReceive r = liftIO $ atomically $ writeTChan receiveChan r

      close :: m ()
      close = do
        onClose sendsRreceivesS Nothing
        onClose sendsSreceivesR Nothing

  sToR <- liftBaseWith $ \runInBase -> async $ forever $ do
    s <- atomically $ readTChan sendChan
    void $ runInBase $ onReceive sendsRreceivesS WebSocketsAppParams
      { send = sendToReceive
      , close
      } s

  rToS <- liftBaseWith $ \runInBase -> async $ forever $ do
    r <- atomically $ readTChan receiveChan
    void $ runInBase $ onReceive sendsSreceivesR WebSocketsAppParams
      { send = sendToSend
      , close
      } r

  onOpen sendsRreceivesS WebSocketsAppParams
    { send = sendToReceive
    , close
    }

  onOpen sendsSreceivesR WebSocketsAppParams
    { send = sendToSend
    , close
    }

  pure (sToR,rToS,sendChan,receiveChan)
