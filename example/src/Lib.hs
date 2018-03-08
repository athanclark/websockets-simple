{-# LANGUAGE
    DeriveGeneric
  #-}

module Lib where

import GHC.Generics (Generic)
import Data.Aeson (ToJSON (..), FromJSON (..), genericToEncoding, defaultOptions)


data Input = Increment | Decrement
  deriving (Generic, Eq, Ord, Show)

instance ToJSON Input where
  toEncoding = genericToEncoding defaultOptions

instance FromJSON Input

data Output = Value Int
  deriving (Generic, Eq, Ord, Show)

instance ToJSON Output where
  toEncoding = genericToEncoding defaultOptions

instance FromJSON Output
