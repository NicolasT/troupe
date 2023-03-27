module Troupe.Queue.Test (tests) where

import Control.Concurrent.Classy (threadDelay)
import Control.Concurrent.Classy.Async (withAsync)
import Control.Concurrent.Classy.STM (check, readTVar, registerDelay, throwSTM)
import Control.Exception.Safe (Exception, try)
import Control.Monad.Conc.Class (atomically)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.DejaFu (testAuto)
import Test.Tasty.HUnit (testCase, (@?=))
import Troupe.Queue (Match (..), dequeue, enqueue, newQueue)

tests :: TestTree
tests =
  testGroup
    "Troupe.Queue"
    [ testCase "Simple" $ do
        q <- atomically newQueue
        atomically $ enqueue q ()
        r <- dequeue q [MatchMessage (\() -> pure True)]
        r @?= True,
      testCase "Less simple" $ do
        q <- atomically newQueue
        d <- registerDelay 1000
        r <- dequeue q [MatchSTM (readTVar d >>= check)]
        r @?= (),
      testCase "Another one" $ do
        q <- atomically newQueue
        d <- registerDelay 100000
        atomically $ enqueue q ()
        r <- dequeue q [MatchMessage (\() -> pure True), MatchSTM (do readTVar d >>= check; pure False)]
        r @?= True,
      testCase "Another one" $ do
        q <- atomically newQueue
        d <- registerDelay 100000
        atomically $ enqueue q ()
        r <- dequeue q [MatchSTM (do readTVar d >>= check; pure False), MatchMessage (\() -> pure True)]
        r @?= True,
      testCase "Old ones" $ do
        q <- atomically newQueue
        atomically $ enqueue q True
        atomically $ enqueue q False
        dequeue q [MatchMessage (\b -> if not b then Just () else Nothing)]
        dequeue q [MatchMessage (\b -> if b then Just () else Nothing)],
      testCase "First one wins" $ do
        q <- atomically newQueue
        r <- dequeue q [MatchSTM (pure True), MatchSTM (pure False)]
        r @?= True,
      testCase "first one still wins" $ do
        q <- atomically newQueue
        atomically $ enqueue q True
        r <-
          dequeue
            q
            [ MatchMessage (\b -> if not b then Just (0 :: Int) else Nothing),
              MatchMessage (\b -> if b then Just 1 else Nothing),
              MatchMessage (\b -> if not b then Just 2 else Nothing),
              MatchMessage (\b -> if b then Just 3 else Nothing)
            ]
        r @?= 1,
      testCase "a" $ do
        q <- atomically newQueue
        atomically $ enqueue q True
        r <- dequeue q [MatchSTM (pure False), MatchMessage Just]
        r @?= False
        r' <- dequeue q [MatchMessage Just, MatchSTM (pure False)]
        r' @?= True,
      testAuto "What gives..." $ do
        q <- atomically newQueue
        atomically $ do
          enqueue q (1 :: Int)
          enqueue q 2
        dequeue
          q
          [ MatchMessage (\i -> if i == 2 then Just i else Nothing),
            MatchMessage (\i -> if i == 3 then Just i else Nothing),
            MatchMessage (\i -> if i == 1 then Just i else Nothing)
          ],
      testAuto "Another" $ do
        q <- atomically newQueue
        dequeue q [MatchMessage (\() -> pure True), MatchSTM (pure False)],
      testAuto "W" $ do
        q <- atomically $ do
          q <- newQueue
          enqueue q ()
          pure q
        dequeue q [MatchMessage (\() -> pure True), MatchSTM (pure False)],
      testAuto "MT" $ do
        q <- atomically newQueue
        withAsync (threadDelay 100000 >> atomically (enqueue q (1 :: Int))) $ \_a ->
          withAsync (threadDelay 1000 >> atomically (enqueue q 2)) $ \_b -> do
            -- Note, we don't synchronise on `a` or `b`, so the `dequeue` returns
            -- either 1 or 2
            r <-
              dequeue
                q
                [ MatchMessage (\i -> if i == 1 then Just i else Nothing),
                  MatchMessage (\i -> if i == 2 then Just i else Nothing)
                ]
            pure $ r == 1 || r == 2,
      testCase "throw" $ do
        q <- atomically newQueue
        atomically $ enqueue q (1 :: Int)

        r <-
          try $
            dequeue
              q
              [ MatchMessage (\i -> if i == 0 then Just i else Nothing),
                MatchSTM (throwSTM TestException),
                MatchMessage Just
              ]
        r @?= Left TestException

        r' <- dequeue q [MatchMessage Just]
        r' @?= 1
    ]

data TestException = TestException
  deriving (Show, Eq)

instance Exception TestException
