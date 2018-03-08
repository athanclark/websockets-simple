{-# LANGUAGE
    OverloadedStrings
  , NamedFieldPuns
  #-}

module Main where

import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..), toServerAppT)
import Lib (Input (..), Output (..))

import Network.WebSockets (defaultConnectionOptions)
import Network.WebSockets (acceptRequest, sendTextData, receiveDataMessage)
import Network.HTTP.Types (status404)
import Network.Wai.Middleware.ContentType.Text (textOnly)
import Network.Wai.Trans (Application, websocketsOrT)
import Network.Wai.Handler.Warp (run)
import Data.Text (Text)
import Control.Monad (forever, void)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO, writeTVar, modifyTVar')


main :: IO ()
main = do
  s <- server
  let s' = toServerAppT s
           -- \pending -> do
           --   conn <- acceptRequest pending
           --   putStrLn "Accepted..."
           --   sendTextData conn ("Uh..." :: Text)
           --   forever $ do
           --     x <- receiveDataMessage conn
           --     putStrLn $ "Got: " ++ show x
  run 3000 (websocketsOrT id defaultConnectionOptions s' defApp)
  where
    defApp :: Application
    defApp _ resp = resp (textOnly "404" status404 [])


server :: IO (WebSocketsApp IO Input Output)
server = do
  countRef <- newTVarIO 0
  emitter <- newTVarIO Nothing

  let killEmitter = do
        mThread <- readTVarIO emitter
        case mThread of
          Nothing -> pure ()
          Just thread -> cancel thread

  pure WebSocketsApp
    { onOpen = \WebSocketsAppParams{send} -> do
        putStrLn "Opened..."
        thread <- async $ forever $ do
          count <- readTVarIO countRef
          putStrLn $ "Sending: " ++ show (Value count)
          send (Value count)
          putStrLn $ "Sent: " ++ show (Value count)
          threadDelay (10^6)
        atomically (writeTVar emitter (Just thread))
    , onReceive = \WebSocketsAppParams{send,close} x -> do
        putStrLn $ "Got: " ++ show x
        count <-
          ( atomically $ modifyTVar' countRef $ case x of
              Increment -> (+ 1)
              Decrement -> (-) 1
          ) *> readTVarIO countRef
        if count >= 10 || count <= -10
          then close
          else do
            putStrLn $ "Sending Response: " ++ show (Value count)
            send (Value count)
            putStrLn $ "Sent Response: " ++ show (Value count)
    , onClose = \e -> do
        putStrLn $ "Closing... " ++ show e
        killEmitter
        atomically $ writeTVar countRef 0
    }
