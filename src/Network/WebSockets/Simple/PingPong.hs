{-# LANGUAGE
    NamedFieldPuns
  , FlexibleContexts
  , OverloadedStrings
  #-}

module Network.WebSockets.Simple.PingPong where

import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..))

import Data.Aeson (ToJSON (..), FromJSON (..))
import Data.Aeson.Types (Value (Array, String), typeMismatch)
import qualified Data.Vector as V
import Control.Monad (forever)
import Control.Monad.Trans.Control (MonadBaseControl (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM (atomically, newEmptyTMVarIO, putTMVar, takeTMVar)


-- | Uses the JSON literal @[]@ as the ping message
newtype PingPong a = PingPong {getPingPong :: Maybe a}

-- | Assumes @a@ isn't an 'Data.Aeson.Types.Array' of anything
instance ToJSON a => ToJSON (PingPong a) where
  toJSON (PingPong Nothing) = String ""
  toJSON (PingPong (Just x)) = toJSON [x]

-- | Assumes @a@ isn't an 'Data.Aeson.Types.Array' of anything
instance FromJSON a => FromJSON (PingPong a) where
  parseJSON x@(String xs)
    | xs == "" = pure (PingPong Nothing)
    | otherwise = typeMismatch "PingPong" x
  parseJSON x@(Array xs)
    | V.length xs /= 1 = typeMismatch "PingPong" x
    | otherwise = (PingPong . Just) <$> parseJSON (xs V.! 0)
  parseJSON x = typeMismatch "PingPong" x



pingPong :: ( MonadBaseControl IO m
            )
         => Int -- ^ Delay in microseconds
         -> WebSocketsApp m receive send
         -> m (WebSocketsApp m (PingPong receive) (PingPong send))
pingPong delay WebSocketsApp{onOpen,onReceive,onClose} = do
  pingingThread <- liftBaseWith $ \_ -> newEmptyTMVarIO

  pure WebSocketsApp
    { onOpen = \params@WebSocketsAppParams{send} -> do
        liftBaseWith $ \runInBase -> do
          counter <- async $ forever $ do
            threadDelay delay
            runInBase $ send $ PingPong Nothing
          atomically $ putTMVar pingingThread counter
        onOpen (mkParams params)
    , onReceive = \params (PingPong mPingPong) ->
        case mPingPong of
          Nothing -> pure ()
          Just r -> onReceive (mkParams params) r
    , onClose = \o e -> do
        liftBaseWith $ \_ -> do
          thread <- atomically (takeTMVar pingingThread)
          cancel thread
        onClose o e
    }
  where
    mkParams WebSocketsAppParams{send,close} = WebSocketsAppParams{send = send . PingPong . Just,close}
