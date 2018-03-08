{-# LANGUAGE
    NamedFieldPuns
  , FlexibleContexts
  #-}

module Network.WebSockets.Simple.PingPong where

import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..))

import Data.Aeson (ToJSON (..), FromJSON (..))
import Data.Aeson.Types (Value (Array))
import Control.Monad.Trans.Control (MonadBaseControl (..))
import Control.Concurrent.Async.Every (every, reset)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)


-- | Uses the JSON literal @[]@ as the ping message
newtype PingPong a = PingPong {getPingPong :: Maybe a}

-- | Assumes @a@ isn't an 'Data.Aeson.Types.Array' of anything
instance ToJSON a => ToJSON (PingPong a) where
  toJSON (PingPong Nothing) = toJSON ([] :: [()])
  toJSON (PingPong (Just x)) = toJSON x

-- | Assumes @a@ isn't an 'Data.Aeson.Types.Array' of anything
instance FromJSON a => FromJSON (PingPong a) where
  parseJSON x@(Array xs)
    | null xs = pure (PingPong Nothing)
    | otherwise = (PingPong . Just) <$> parseJSON x
  parseJSON x = (PingPong . Just) <$> parseJSON x



pingPong :: ( MonadBaseControl IO m
            )
         => Int -- ^ Delay in microseconds
         -> WebSocketsApp m receive send
         -> m (WebSocketsApp m (PingPong receive) (PingPong send))
pingPong delay WebSocketsApp{onOpen,onReceive,onClose} = do
  counterVar <- liftBaseWith $ \_ -> newTVarIO Nothing

  let halfDelay = delay `div` 2

  pure WebSocketsApp
    { onOpen = \WebSocketsAppParams{send,close} -> do
        liftBaseWith $ \runInBase -> do
          counter <- every delay (Just halfDelay) $ runInBase $
            send (PingPong Nothing)
          atomically $ writeTVar counterVar (Just counter)
        onOpen WebSocketsAppParams{send = send . PingPong . Just, close}
    , onReceive = \WebSocketsAppParams{send,close} (PingPong mPingPong) ->
        case mPingPong of
          Nothing -> liftBaseWith $ \_ -> do
            mCounter <- atomically $ readTVar counterVar
            case mCounter of
              Nothing -> error "somehow received message before socket was opened"
              Just counter -> reset (Just halfDelay) counter
          Just r -> onReceive WebSocketsAppParams{send = send . PingPong . Just, close} r
    , onClose
    }
