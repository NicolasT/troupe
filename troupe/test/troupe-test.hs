module Main (main) where

import Test.Tasty (defaultMain, testGroup)
import qualified Troupe.Test as T

main :: IO ()
main =
  defaultMain $
    testGroup
      "troupe-test"
      [ T.tests
      ]
