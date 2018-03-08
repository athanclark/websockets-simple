{-# LANGUAGE
    NamedFieldPuns
  #-}

module Main where

import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..), toClientAppT', expBackoffStrategy)
import Lib (Input (..), Output (..))

import Network.WebSockets (runClient)
import Control.Monad (forM_, forever, void)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Concurrent.STM (atomically, TChan, newTChanIO, readTChan, writeTChan)


main :: IO ()
main = do
  invokeChan <- newTChanIO

  c <- client invokeChan

  atomically $ writeTChan invokeChan ()

  forever $ do
    _ <- atomically $ readTChan invokeChan
    putStrLn "Opening..."
    runClient "localhost" 3000 "/" (toClientAppT' c)


client :: TChan () -> IO (WebSocketsApp IO Output Input)
client invokeChan = do
  onClose <- expBackoffStrategy (atomically $ writeTChan invokeChan ())

  pure mempty
    { onOpen = \WebSocketsAppParams{send} -> do
        putStrLn "Opened..."
        forM_ [1..10] $ \_ -> do
          send Increment
          putStrLn $ "Sent: " ++ show Increment
          threadDelay (10^6)
    , onClose = \e -> do
        putStrLn $ "Closing: " ++ show e
        onClose e
    }
