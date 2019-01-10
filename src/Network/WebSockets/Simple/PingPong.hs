{-# LANGUAGE
    NamedFieldPuns
  , FlexibleContexts
  , OverloadedStrings
  , GeneralizedNewtypeDeriving
  , DeriveGeneric
  , ScopedTypeVariables
  , DataKinds
  #-}

module Network.WebSockets.Simple.PingPong where

import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..))

import Data.Aeson (ToJSON (..), FromJSON (..))
import Data.Aeson.JSONMaybe (JSONMaybe (..))
import Data.Singleton.Class (Extractable (..))
import Control.Monad (forever)
import Control.Monad.Trans.Control.Aligned (MonadBaseControl (..))
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM (atomically, newEmptyTMVarIO, putTMVar, takeTMVar)
import Control.Concurrent.Chan.Typed (newChanRW, writeChanRW, readChanRW, ChanRW)
import Control.Concurrent.Chan.Scope (Scope (Read))
import Control.Concurrent.Chan.Extra (intersperseStatic, DiffNanosec, readOnly)
import GHC.Generics (Generic)



-- | Uses the JSON literal @[]@ as the ping message
newtype PingPong a = PingPong
  { getPingPong :: JSONMaybe a
  } deriving (Eq, Ord, Show, Generic, ToJSON, FromJSON)


data PingPongDecay send
  = PingPongSend send
  | PingPongReceivedAny
  | PingPongPing


-- | Facilitate a ping-pong enriched websocket, with ping 
pingPong :: ( MonadBaseControl IO m stM
            , Extractable stM
            )
         => DiffNanosec -- ^ Initial delay in microseconds
         -> WebSocketsApp m receive send
         -> m (WebSocketsApp m (PingPong receive) (PingPong send))
pingPong delay WebSocketsApp{onOpen,onReceive,onClose} = liftBaseWith $ \_ -> do
  (outgoing :: ChanRW 'Read (PingPongDecay send)) <- readOnly <$> newChanRW
  (sendable,writer,listener) <- intersperseStatic delay (pure PingPongPing) outgoing

  let send' x = liftBaseWith $ \_ -> writeChanRW sendable (PingPongSend x)
      mkParams WebSocketsAppParams{close} =
        WebSocketsAppParams{send = send', close}

  sendingThread <- newEmptyTMVarIO

  pure WebSocketsApp
    { onOpen = \params@WebSocketsAppParams{send} -> do
        liftBaseWith $ \runInBase -> do
          sender <- async $ forever $ do
            ex <- readChanRW outgoing
            runInBase $ case ex of
              PingPongPing -> send (PingPong JSONNothing)
              PingPongSend x -> send $ PingPong $ JSONJust x
              _ -> pure ()
          atomically (putTMVar sendingThread sender)
        onOpen (mkParams params)
    , onReceive = \params (PingPong mPingPong) -> do
        liftBaseWith $ \_ -> writeChanRW sendable PingPongReceivedAny
        case mPingPong of
          JSONNothing -> pure ()
          JSONJust r -> onReceive (mkParams params) r
    , onClose = \o e -> do
        liftBaseWith $ \_ -> do
          thread <- atomically (takeTMVar sendingThread)
          cancel thread
          cancel writer
          cancel listener
        onClose o e
    }
