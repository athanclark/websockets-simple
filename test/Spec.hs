{-# LANGUAGE
    NamedFieldPuns
  #-}

module Main where

import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..))
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan (TChan, writeTChan, newTChanIO, readTChan)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.Hspec (testSpec)
import Test.Hspec (runIO, it)
import Test.WebSockets.Simple (runConnected)


testReceivingApp :: TChan Int -> WebSocketsApp Int Int IO
testReceivingApp receivedChan = WebSocketsApp
  { onOpen = \WebSocketsAppParams{send} ->
      send 0
  , onReceive = \_ x ->
      atomically $ writeTChan receivedChan x
  , onClose = \_ -> pure ()
  }

testSendingApp :: WebSocketsApp Int Int IO
testSendingApp = WebSocketsApp
  { onOpen = \_ -> pure ()
  , onReceive = \WebSocketsAppParams{send} x ->
      send x
  , onClose = \_ -> pure ()
  }


main :: IO ()
main = do
  rwChan <- newTChanIO

  _ <- runConnected (testReceivingApp rwChan) testSendingApp


  rwSpec <- testSpec "Atomic writes and receipts" $ do
    out <- runIO $ atomically $ readTChan rwChan
    it "has produced a receieved relay" $ out == 0

  defaultMain $ testGroup "WebSockets Simple"
    [ rwSpec
    ]