{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}

module Troupe.Test (tests) where

import Control.Concurrent
  ( getNumCapabilities,
    isCurrentThreadBound,
    myThreadId,
    newEmptyMVar,
    putMVar,
    takeMVar,
    threadCapability,
  )
import Control.DeepSeq (NFData (..))
import Control.Exception.Base (MaskingState (..), getMaskingState)
import Control.Exception.Safe (Exception, Handler (..), bracket, catch, catchesAsync, fromException, mask, throwM)
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)
import GHC.Generics (Generic)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))
import Troupe
  ( DemonitorOption (..),
    Down (..),
    Exit (..),
    Killed (..),
    NoProc (..),
    Process,
    ProcessId,
    ProcessOption (..),
    SpawnOptions (..),
    ThreadAffinity (..),
    WithMonitor (..),
    demonitor,
    exit,
    expect,
    isProcessAlive,
    kill,
    link,
    match,
    matchIf,
    monitor,
    receive,
    receiveTimeout,
    runNode,
    self,
    send,
    setProcessOption,
    spawn,
    spawnLink,
    spawnMonitor,
    spawnWithOptions,
    pattern IsExit,
  )

troupeTest :: r -> Process r a -> Assertion
troupeTest r root = do
  m <- newEmptyMVar

  runNode r $ do
    (_, ref) <- spawnMonitor root
    receive
      [ matchIf
          (\d -> downMonitorRef d == ref)
          ( \d -> liftIO $ case downReason d of
              Nothing -> putMVar m (Right ())
              Just exc -> putMVar m (Left exc)
          )
      ]

  takeMVar m >>= \case
    Left exc -> throwM exc
    Right () -> pure ()

newtype Ping = Ping ProcessId
  deriving newtype (NFData)

data Pong = Pong
  deriving (Generic)
  deriving anyclass (NFData)

data TestException = TestException
  deriving (Show, Eq)

instance Exception TestException

instance NFData TestException where
  rnf t = t `seq` ()

tests :: TestTree
tests =
  testGroup
    "Troupe"
    [ testCase "Ping-pong" $ troupeTest () $ do
        let ponger = forever $ do
              Ping p <- expect
              send p Pong

        withProcess ponger $ \pid -> do
          send pid . Ping =<< self
          Pong <- expect
          pure (),
      testCase "spawnLink" $ troupeTest () $ do
        (_, ref) <- spawnMonitor $ do
          _ <- spawnLink $ throwM TestException
          () <- expect
          liftIO $ assertFailure "This should not be reached"
        Down ref' _ exc <- expect
        liftIO $ do
          ref' @?= ref
          case exc of
            Nothing -> assertFailure "Expected an exception"
            Just exc' -> case fromException exc' of
              Nothing -> assertFailure "Expected an Exit exception"
              Just e -> do
                exitLink e @?= True
                case exitReason e of
                  Nothing -> assertFailure "Expected an Exit with a reason"
                  Just t -> case fromException t of
                    Nothing -> assertFailure "Expected a TestException as reason"
                    Just TestException -> pure (),
      testGroup
        "link"
        [ testCase "Simple scenario" $ troupeTest () $ do
            (pid1, ref1) <- spawnMonitor $ do
              -- Block
              () <- expect
              pure ()

            (pid2, ref2) <- spawnMonitor $ do
              link pid1
              throwM TestException

            down1 <-
              receive
                [ matchIf (\d -> downMonitorRef d == ref1) pure
                ]
            down2 <-
              receive
                [ matchIf (\d -> downMonitorRef d == ref2) pure
                ]

            liftIO $ do
              downMonitorRef down1 @?= ref1
              downProcessId down1 @?= pid1
              case downReason down1 of
                Nothing -> assertFailure "Expected downReason to be some exception"
                Just dr -> case fromException dr of
                  Nothing -> assertFailure $ "Expected downReason to be an Exit exception: " <> show dr
                  Just e -> case exitReason e of
                    Nothing -> assertFailure "Expected exitReason to be some exception"
                    Just er -> case fromException er of
                      Nothing -> assertFailure $ "Expected exitReason to be a TestException: " <> show er
                      Just TestException -> pure ()

              downMonitorRef down2 @?= ref2
              downProcessId down2 @?= pid2
              case downReason down2 of
                Nothing -> assertFailure "Expected downReason to be some exception"
                Just dr -> case fromException dr of
                  Nothing -> assertFailure $ "Expected downReason to be a TestException: " <> show dr
                  Just TestException -> pure ()

            receiveTimeout 0 [match pure] >>= \case
              Nothing -> pure ()
              Just Down {} -> liftIO $ assertFailure "unexpected Down message",
          testGroup
            "link is bidirectional"
            [ testCase "linker throws" $ troupeTest () $ do
                (pid1, ref1) <- spawnMonitor $ do
                  () <- expect
                  pure ()
                (_, ref2) <- spawnMonitor $ do
                  link pid1
                  throwM TestException
                awaitProcessExit ref1
                awaitProcessExit ref2,
              testCase "linkee throws" $ troupeTest () $ do
                m <- liftIO newEmptyMVar

                (pid1, ref1) <- spawnMonitor $ do
                  liftIO $ takeMVar m
                  throwM TestException

                (_, ref2) <- spawnMonitor $ do
                  link pid1
                  mask $ \restore -> do
                    liftIO $ putMVar m ()
                    restore $ do
                      () <- expect
                      pure ()

                awaitProcessExit ref1
                awaitProcessExit ref2
            ]
        ],
      testGroup
        "monitor"
        [ testCase "Unexceptional" $ troupeTest () $ do
            m <- liftIO newEmptyMVar
            pid <- spawn $ liftIO $ takeMVar m
            ref <- monitor pid
            liftIO $ putMVar m ()

            Down ref' pid' Nothing <- expect
            liftIO $ do
              ref' @?= ref
              pid' @?= pid,
          testCase "Exceptional" $ troupeTest () $ do
            m <- liftIO newEmptyMVar
            pid <- spawn $ do
              liftIO $ takeMVar m
              throwM TestException
            ref <- monitor pid
            liftIO $ putMVar m ()

            Down ref' pid' (Just exc) <- expect
            liftIO $ do
              ref' @?= ref
              pid' @?= pid
              fromException exc @?= Just TestException,
          testCase "NoProc" $ troupeTest () $ do
            (pid, ref) <- spawnMonitor (pure ())
            awaitProcessExit ref

            -- Here, we know `pid` already exited
            ref2 <- monitor pid
            Down ref2' pid' (Just exc) <- expect
            liftIO $ do
              ref2' @?= ref2
              pid' @?= pid
              fromException exc @?= Just (NoProc pid)
        ],
      testGroup
        "demonitor"
        [ testCase "Default" $ troupeTest () $ do
            _ <- setProcessOption TrapExit True
            m <- liftIO newEmptyMVar
            (pid, ref) <- spawnMonitor (liftIO $ takeMVar m)
            link pid
            demonitor [] ref
            liftIO $ putMVar m ()
            Exit _ _ _ Nothing <- expect
            receiveTimeout 0 [matchMonitor ref] >>= \res -> liftIO $ do
              res @?= Nothing,
          testCase "DemonitorFlush" $ troupeTest () $ do
            m <- liftIO newEmptyMVar
            (pid, ref) <- spawnMonitor $ do
              liftIO $ takeMVar m
              throwM TestException
            (_, ref2) <- spawnMonitor $ do
              link pid
              liftIO $ putMVar m ()
              () <- expect
              pure ()

            receive [matchMonitor ref]
            demonitor [DemonitorFlush] ref2
            receiveTimeout 0 [matchMonitor ref2] >>= \res -> liftIO $ do
              res @?= Nothing
        ],
      testGroup
        "ProcessOption"
        [ testGroup
            "TrapExit"
            [ testCase "Unexceptional" $ troupeTest () $ do
                _ <- setProcessOption TrapExit True
                pid <- spawnLink (pure ())
                Exit pid' _ True Nothing <- expect
                liftIO $ pid' @?= pid,
              testCase "Exceptional" $ troupeTest () $ do
                _ <- setProcessOption TrapExit True
                pid <- spawnLink (throwM TestException)
                Exit pid' _ True (Just exc) <- expect
                liftIO $ do
                  pid' @?= pid
                  fromException exc @?= Just TestException
            ]
        ],
      testGroup
        "spawnWithOptions"
        [ let affinityTest affinity action = troupeTest () $ do
                s <- self
                _ <- spawnWithOptions (SpawnOptions True WithoutMonitor affinity) $ do
                  _ <- action
                  send s ()
                () <- expect
                pure ()
              assertUnmasked = do
                s <- getMaskingState
                s @?= Unmasked
           in testGroup
                "ThreadAffinity"
                [ testCase "Unbound" $ affinityTest Unbound $ liftIO $ do
                    assertUnmasked
                    isBound <- isCurrentThreadBound
                    isBound @?= False
                    (_, bounded) <- threadCapability =<< myThreadId
                    bounded @?= False,
                  testCase "Capability _" $ do
                    nc <- liftIO getNumCapabilities
                    let c = nc - 1
                    affinityTest (Capability c) $ liftIO $ do
                      assertUnmasked
                      isBound <- isCurrentThreadBound
                      isBound @?= False
                      (n, bounded) <- threadCapability =<< myThreadId
                      n @?= c
                      bounded @?= True
                      {- -- This is blocked by https://github.com/NicolasT/troupe/issues/28
                      testCase "OsThread" $ affinityTest OsThread $ liftIO $ do
                        assertUnmasked
                        isBound <- isCurrentThreadBound
                        isBound @?= True
                        (_, bounded) <- threadCapability =<< myThreadId
                        bounded @?= False
                       -}
                ]
        ],
      testGroup
        "exit"
        [ testGroup
            "No TrapExit"
            [ testCase "No exception" $ troupeTest () $ do
                m <- liftIO newEmptyMVar
                s <- self

                (pid, ref) <- spawnMonitor $ do
                  liftIO $ takeMVar m
                  send s ()

                exit pid (Nothing :: Maybe TestException)

                liftIO $ putMVar m ()
                () <- expect
                awaitProcessExit ref,
              testCase "Regular exception" $ troupeTest () $ do
                (pid, _) <- spawnMonitor $ do
                  () <- expect
                  pure ()

                exit pid (Just TestException)

                Down _ pid' exc <- expect
                liftIO $ do
                  pid' @?= pid
                  fmap fromException exc @?= Just (Just TestException),
              testCase "Regular exception, catching" $ troupeTest () $ do
                s <- self
                (pid, _) <- spawnMonitor $ do
                  (do () <- expect; pure ()) `catch` \TestException -> send s ()

                exit pid (Just TestException)
                () <- expect

                Down _ _ Nothing <- expect
                pure (),
              testCase "Kill" $ troupeTest () $ do
                (pid, _) <- spawnMonitor $ do
                  () <- expect
                  pure ()

                exit pid (Just $ kill "Die")

                Down _ pid' exc <- expect
                liftIO $ do
                  pid' @?= pid
                  fmap fromException exc @?= Just (Just $ Killed "Die"),
              testCase "Kill accross a link" $ troupeTest () $ do
                s <- self

                (pid1, ref1) <- spawnMonitor $ do
                  s' <- self
                  link s
                  pid2 <- expect
                  send pid2 ()
                  (do () <- expect; pure ())
                    `catchesAsync` [ Handler
                                       ( \e@Exit {} -> do
                                           liftIO $ do
                                             exitSender e @?= pid2
                                             exitReceiver e @?= s'
                                             exitLink e @?= True
                                             fmap fromException (exitReason e) @?= Just (Just (Killed "Die"))
                                           send s ()
                                       )
                                   ]

                (pid2, ref2) <- spawnMonitor $ do
                  link pid1
                  s' <- self
                  send pid1 s'
                  () <- expect
                  send s ()
                  (do () <- expect; pure ())

                () <- expect
                exit pid2 (Just $ kill "Die")

                () <- expect

                awaitProcessExit ref2
                awaitProcessExit ref1
            ],
          testGroup
            "TrapExit"
            [ testCase "No exception" $ troupeTest () $ do
                s <- self

                (pid, ref) <- spawnMonitor $ do
                  _ <- setProcessOption TrapExit True
                  send s ()
                  pid <- self
                  Exit s' pid' False Nothing <- expect
                  liftIO $ do
                    s' @?= s
                    pid' @?= pid

                link pid
                () <- expect
                exit pid (Nothing :: Maybe TestException)
                awaitProcessExit ref,
              testCase "Regular exception" $ troupeTest () $ do
                s <- self

                (pid, ref) <- spawnMonitor $ do
                  _ <- setProcessOption TrapExit True
                  send s ()
                  pid <- self
                  Exit s' pid' False (Just exc) <- expect
                  liftIO $ do
                    s' @?= s
                    pid' @?= pid
                    fromException exc @?= Just TestException

                link pid
                () <- expect
                exit pid (Just TestException)
                awaitProcessExit ref,
              testCase "Kill" $ troupeTest () $ do
                s <- self

                (pid, _) <- spawnMonitor $ do
                  _ <- setProcessOption TrapExit True
                  send s ()
                  () <- expect
                  pure ()

                () <- expect
                exit pid (Just $ kill "Die")
                Down _ _ (Just exc) <- expect
                liftIO $ fromException exc @?= Just (Killed "Die")
            ]
        ],
      testCase "isProcessAlive" $ troupeTest () $ do
        (pid, ref) <- spawnMonitor $ do
          () <- expect
          pure ()

        a <- isProcessAlive pid
        liftIO $ a @?= True

        exit pid (Just $ kill "Die")
        awaitProcessExit ref

        a' <- isProcessAlive pid
        liftIO $ a' @?= False,
      testGroup
        "Non-regression"
        [ testCase "Deliver signals before/when receiving messages (#25)" $ troupeTest () $ do
            -- The "main" test thread
            (_, _) <- spawnMonitor $ do
              mv <- liftIO newEmptyMVar
              -- The child thread
              pid <- spawnLink $ do
                liftIO $ takeMVar mv
                -- Unconditional failure
                throwM TestException
              -- When this returns, the main thread is linked to the thread,
              -- and monitoring it.
              _ref <- monitor pid
              liftIO $ putMVar mv ()

              -- Wait for the monitor. However, if `Down` is delivered, this
              -- is because the child exited, with an exception (there's no
              -- other way for it to exit), in which case, through the link,
              -- this thread should be killed as well. Hence, `expect` should
              -- not return and this process should exit with an exception,
              -- as observed by the test process through a monitor.
              --
              -- Before the fix, putting a
              -- () <- expect
              -- here, which will never be fulfilled, makes the test succeed:
              -- this thread blocks, the Exit exception from the link can be
              -- injected, and we're good.
              Down {} <- expect
              pure ()

            Down _ _ exc <- expect

            liftIO $ case exc of
              Just (IsExit _ _ True (Just exc')) -> fromException exc' @?= Just TestException
              _ -> assertFailure "Expected an Exit exception"
        ]
    ]
  where
    matchMonitor ref = matchIf (\d -> downMonitorRef d == ref) (\_ -> pure ())
    awaitProcessExit ref = receive [matchMonitor ref]
    withProcess p act = bracket (spawnMonitor p) cleanup (\(pid, _) -> act pid)
      where
        cleanup (pid, ref) = do
          exit pid (Just $ kill "End of withProcess scope")
          awaitProcessExit ref
