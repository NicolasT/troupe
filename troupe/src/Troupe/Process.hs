{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE Strict #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}

module Troupe.Process
  ( NodeContext (..),
    newNodeContext,
    newProcessContext,
    ProcessEnv (..),
    MonadProcess (..),
    Process,
    runProcess,
    self,
    ProcessOption (..),
    setProcessOption,
    getProcessOption,
    link,
    unlink,
    monitor,
    DemonitorOption (..),
    demonitor,
    exit,
    isProcessAlive,
    spawnWithOptions,
    SpawnOptions (..),
    ThreadAffinity (..),
    WithMonitor (..),
    send,
    sendLazy,
    receive,
    Match,
    matchIf,
    after,
  )
where

import Control.Applicative (Alternative, (<|>))
import Control.Concurrent (throwTo)
import Control.Concurrent.Async
  ( async,
    asyncThreadId,
    uninterruptibleCancel,
    waitCatchSTM,
    withAsyncOnWithUnmask,
    withAsyncWithUnmask,
  )
import Control.Concurrent.STM
  ( STM,
    TQueue,
    TVar,
    atomically,
    check,
    isEmptyTQueue,
    newEmptyTMVarIO,
    newTQueue,
    newTVar,
    newTVarIO,
    readTMVar,
    readTQueue,
    readTVar,
    registerDelay,
    throwSTM,
    tryReadTMVar,
    writeTMVar,
    writeTQueue,
    writeTVar,
  )
import Control.DeepSeq (NFData, deepseq, ($!!))
import Control.Distributed.Process.Internal.CQueue
  ( BlockSpec (..),
    CQueue,
    MatchOn (..),
    dequeue,
    enqueueSTM,
    newCQueue,
  )
import Control.Exception.Safe
  ( Exception (..),
    IOException,
    MonadCatch,
    MonadMask,
    MonadThrow,
    SomeException,
    bracketOnError,
    finally,
    mask_,
    throwM,
    toException,
    uninterruptibleMask_,
    withException,
  )
import Control.Monad (MonadPlus, forM, unless, when)
import Control.Monad.Error.Class (MonadError)
import Control.Monad.Fix (MonadFix)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Primitive (PrimMonad)
import Control.Monad.Random.Class (MonadRandom, MonadSplit)
import Control.Monad.Reader.Class (MonadReader (..))
import Control.Monad.Time (MonadTime)
import Control.Monad.Trans (MonadTrans, lift)
import Control.Monad.Trans.Accum (AccumT)
import Control.Monad.Trans.Cont (ContT)
import Control.Monad.Trans.Except (ExceptT)
import Control.Monad.Trans.Identity (IdentityT)
import Control.Monad.Trans.Maybe (MaybeT)
import qualified Control.Monad.Trans.RWS.CPS as CPS (RWST)
import qualified Control.Monad.Trans.RWS.Lazy as Lazy (RWST)
import qualified Control.Monad.Trans.RWS.Strict as Strict (RWST)
import qualified Control.Monad.Trans.Random.Lazy as Lazy (RandT)
import qualified Control.Monad.Trans.Random.Strict as Strict (RandT)
import Control.Monad.Trans.Reader (ReaderT, runReaderT, withReaderT)
import Control.Monad.Trans.Select (SelectT)
import qualified Control.Monad.Trans.State.Lazy as Lazy (StateT)
import qualified Control.Monad.Trans.State.Strict as Strict (StateT)
import qualified Control.Monad.Trans.Writer.CPS as CPS (WriterT)
import qualified Control.Monad.Trans.Writer.Lazy as Lazy (WriterT)
import qualified Control.Monad.Trans.Writer.Strict as Strict (WriterT)
import Data.Dynamic (Dynamic, fromDynamic, toDyn)
import Data.Maybe (isJust)
import Data.Typeable (Typeable)
import DeferredFolds.UnfoldlM (forM_)
import StmContainers.Map (Map)
import qualified StmContainers.Map as Map
import StmContainers.Set (Set)
import qualified StmContainers.Set as Set
import System.Random (StdGen)
import System.Random.Stateful (AtomicGenM, IOGenM, RandomGenM)
import Troupe.Exceptions (Exit (..), InvalidMonitorRef (..), Kill (..), Killed (..), NoProc (..), isKill)
import Troupe.Types
  ( Down (..),
    MonitorRef (..),
    MonitorRefId,
    ProcessId,
    monitorRefId0,
    processId0,
    succMonitorRefId,
    succProcessId,
  )

data NodeContext r = NodeContext
  { nodeContextNextProcessId :: {-# UNPACK #-} !(TVar ProcessId),
    nodeContextNextMonitorRefId :: {-# UNPACK #-} !(TVar MonitorRefId),
    nodeContextProcesses :: {-# UNPACK #-} !(Map ProcessId ProcessContext),
    nodeContextR :: r
  }

newNodeContext :: r -> IO (NodeContext r)
newNodeContext r =
  NodeContext
    <$> newTVarIO processId0
    <*> newTVarIO monitorRefId0
    <*> Map.newIO
    <*> pure r

data ProcessContext = ProcessContext
  { processContextId :: {-# UNPACK #-} !ProcessId,
    processContextQueue :: {-# UNPACK #-} !(CQueue Dynamic),
    processContextExceptions :: {-# UNPACK #-} !(TQueue SomeException),
    processContextTrapExit :: {-# UNPACK #-} !(TVar Bool),
    processContextLinks :: {-# UNPACK #-} !(Set ProcessId),
    processContextMonitors :: {-# UNPACK #-} !(Set MonitorRef),
    processContextMonitorees :: {-# UNPACK #-} !(Set MonitorRef)
  }

newProcessContextSTM :: CQueue Dynamic -> ReaderT (NodeContext r) STM ProcessContext
newProcessContextSTM queue = do
  pid <- newPid
  lift $
    ProcessContext pid queue
      <$> newTQueue
      <*> newTVar False
      <*> Set.new
      <*> Set.new
      <*> Set.new
  where
    newPid = do
      curr <- readTVarR nodeContextNextProcessId
      writeTVarR nodeContextNextProcessId $!! succProcessId curr
      pure curr

newProcessContext :: NodeContext r -> IO ProcessContext
newProcessContext nodeContext = do
  queue <- newCQueue
  atomically $ runReaderT (newProcessContextSTM queue) nodeContext

data ProcessEnv r = ProcessEnv
  { processEnvNodeContext :: {-# UNPACK #-} !(NodeContext r),
    processEnvProcessContext :: {-# UNPACK #-} !ProcessContext
  }

-- | @mtl@-style class to bring 'Process' support to transformers.
class (Monad m) => MonadProcess r m | m -> r where
  -- | Get the 'ProcessEnv'. This can't be implemented outside of the @troupe@
  -- library, so any transformer should just 'lift' the action, as the default
  -- implementation does.
  getProcessEnv :: m (ProcessEnv r)
  default getProcessEnv :: (MonadProcess r n, MonadTrans t, m ~ t n) => m (ProcessEnv r)
  getProcessEnv = lift getProcessEnv

instance (MonadProcess r m, Monoid w) => MonadProcess r (AccumT w m)

instance (MonadProcess r m) => MonadProcess r (ContT r m)

instance (MonadProcess r m) => MonadProcess r (ExceptT e m)

instance (MonadProcess r m) => MonadProcess r (IdentityT m)

instance (MonadProcess r m) => MonadProcess r (MaybeT m)

instance (MonadProcess r m) => MonadProcess r (CPS.RWST r w s m)

instance (MonadProcess r m, Monoid w) => MonadProcess r (Lazy.RWST r w s m)

instance (MonadProcess r m, Monoid w) => MonadProcess r (Strict.RWST r w s m)

instance (MonadProcess r m) => MonadProcess r (ReaderT t m)

instance (MonadProcess r m) => MonadProcess r (SelectT s m)

instance (MonadProcess r m) => MonadProcess r (Lazy.StateT s m)

instance (MonadProcess r m) => MonadProcess r (Strict.StateT s m)

instance (MonadProcess r m) => MonadProcess r (CPS.WriterT w m)

instance (MonadProcess r m, Monoid w) => MonadProcess r (Lazy.WriterT w m)

instance (MonadProcess r m, Monoid w) => MonadProcess r (Strict.WriterT w m)

instance (MonadProcess r m) => MonadProcess r (Lazy.RandT g m)

instance (MonadProcess r m) => MonadProcess r (Strict.RandT g m)

-- | Base monad for any process.
--
-- The @r@ type variable defines the type of the 'MonadReader' context that
-- will be available in the 'Process', and any 'Process' spawned from it.
newtype Process r a = Process {unProcess :: ReaderT (ProcessEnv r) IO a}
  deriving newtype
    ( Functor,
      Applicative,
      Monad,
      MonadFail,
      MonadFix,
      MonadIO,
      MonadPlus,
      Alternative,
      MonadError IOException,
      MonadThrow,
      MonadCatch,
      MonadMask,
      MonadRandom,
      MonadSplit StdGen,
      RandomGenM (IOGenM s) s,
      RandomGenM (AtomicGenM s) s,
      MonadTime,
      PrimMonad
    )

instance MonadProcess r (Process r) where
  getProcessEnv = Process ask
  {-# INLINE getProcessEnv #-}

instance MonadReader r (Process r) where
  ask = Process $ reader (nodeContextR . processEnvNodeContext)
  reader f = Process $ reader (f . nodeContextR . processEnvNodeContext)
  local f (Process a) = Process $ local mapR a
    where
      mapR env =
        env
          { processEnvNodeContext =
              (processEnvNodeContext env)
                { nodeContextR = f (nodeContextR (processEnvNodeContext env))
                }
          }

runProcess :: Process r a -> ProcessEnv r -> IO a
runProcess = runReaderT . unProcess

-- | Get the 'ProcessId' of the running process.
self :: (MonadProcess r m) => m ProcessId
self = processContextId . processEnvProcessContext <$> getProcessEnv
{-# INLINE self #-}
{-# SPECIALIZE self :: Process r ProcessId #-}

writeTVarR :: (r -> TVar a) -> a -> ReaderT r STM ()
writeTVarR g a = reader g >>= \v -> lift (writeTVar v a)
{-# INLINE writeTVarR #-}

readTVarR :: (r -> TVar a) -> ReaderT r STM a
readTVarR g = reader g >>= \v -> lift (readTVar v)
{-# INLINE readTVarR #-}

liftMonadProcess :: (MonadProcess r m, MonadIO m) => (ProcessEnv r -> s) -> ReaderT s STM a -> m a
liftMonadProcess fn act = getProcessEnv >>= \e -> liftIO $ atomically $ runReaderT act (fn e)
{-# INLINE liftMonadProcess #-}

-- | Options that can change behaviour of a process.
--
-- The type argument defines the type of the option.
--
-- See 'setProcessOption' and 'getProcessOption'.
data ProcessOption t where
  -- | When a 'link'ed process stops, notify the process by sending an 'Exit'
  -- message to its mailbox, instead of killing it (if the 'link'ed process
  -- exited with an exception).
  TrapExit :: ProcessOption Bool

setProcessOptionSTM :: ProcessOption t -> t -> ReaderT ProcessContext STM ()
setProcessOptionSTM !option !t = case option of
  TrapExit -> writeTVarR processContextTrapExit $!! t

-- | Set a 'ProcessOption' setting, returning the previous value.
setProcessOption :: (MonadProcess r m, MonadIO m) => ProcessOption t -> t -> m t
setProcessOption option t = do
  env <- processEnvProcessContext <$> getProcessEnv
  liftIO $ atomically $ flip runReaderT env $ do
    curr <- getProcessOptionSTM option
    setProcessOptionSTM option t
    pure curr
{-# SPECIALIZE setProcessOption :: ProcessOption t -> t -> Process r t #-}

getProcessOptionSTM :: ProcessOption t -> ReaderT ProcessContext STM t
getProcessOptionSTM !option = case option of
  TrapExit -> readTVarR processContextTrapExit

-- | Get a 'ProcessOption' setting.
getProcessOption :: (MonadProcess r m, MonadIO m) => ProcessOption t -> m t
getProcessOption = liftMonadProcess processEnvProcessContext . getProcessOptionSTM
{-# SPECIALIZE getProcessOption :: ProcessOption t -> Process r t #-}

sendLazySTM :: (Typeable a) => ProcessContext -> a -> STM ()
sendLazySTM !pc !a = enqueueSTM (processContextQueue pc) (toDyn a)

deliverException :: ProcessContext -> SomeException -> STM ()
deliverException !pc !exc = writeTQueue (processContextExceptions pc) exc

convertKillToKilled :: SomeException -> SomeException
convertKillToKilled exc = case fromException exc of
  Just (Kill msg) -> toException $ Killed msg
  Nothing -> exc

deliverExit :: ProcessContext -> Exit -> STM ()
deliverExit !pc !exc = do
  let exc' = exc {exitReason = fmap convertKillToKilled (exitReason exc)}
  readTVar (processContextTrapExit pc) >>= \case
    True -> sendLazySTM pc exc'
    False -> case exitReason exc' of
      Nothing -> pure () -- Process exited without exception
      Just _ -> deliverException pc (toException exc')

lookupProcess :: ProcessId -> ReaderT (NodeContext r) STM (Maybe ProcessContext)
lookupProcess !pid = reader nodeContextProcesses >>= lift . Map.lookup pid

linkSTM :: ProcessId -> ReaderT (ProcessEnv r) STM ()
linkSTM !pid = do
  thisProcess <- reader processEnvProcessContext
  -- Linking to yourself is a no-op
  unless (pid == processContextId thisProcess) $ do
    withReaderT processEnvNodeContext (lookupProcess pid) >>= \case
      Nothing -> lift $ do
        let exc = Exit pid (processContextId thisProcess) True (Just $ toException $ NoProc pid)
        deliverExit thisProcess exc
      Just pc -> lift $ do
        Set.insert (processContextId thisProcess) (processContextLinks pc)
        Set.insert pid (processContextLinks thisProcess)

-- | Link the current process to another one.
--
-- Links are bidirectional.
--
-- If 'TrapExit' is not set (the default), and a 'link'ed process stops with
-- an exception, the other end of the link will receive an 'Exit' signal and
-- hence stop as well. When a 'link'ed process stops without an exception,
-- nothing happens.
--
-- If 'TrapExit' is set, and a 'link'ed process stops, an 'Exit' message is
-- delivered to the 'link'ed process' mailbox.
link :: (MonadProcess r m, MonadIO m) => ProcessId -> m ()
link = liftMonadProcess id . linkSTM
{-# SPECIALIZE link :: ProcessId -> Process r () #-}

unlinkSTM :: ProcessId -> ReaderT (ProcessEnv r) STM ()
unlinkSTM !pid =
  withReaderT processEnvNodeContext (lookupProcess pid) >>= \case
    Nothing -> do
      -- If all is good, the pid is not in our local links set since
      -- either no link to the PID was ever created (`linkSTM` delivered
      -- an error), or the PID is dead and hence, the link was removed
      -- already.
      -- Since we can't discern between the two cases, there's no invariant
      -- to check here.
      pure ()
    Just pc -> do
      thisProcess <- reader processEnvProcessContext
      lift $ do
        Set.delete (processContextId thisProcess) (processContextLinks pc)
        Set.delete pid (processContextLinks thisProcess)

-- | Unlink the current process from another one.
--
-- Like 'link', this works bidirectionally.
--
-- See 'link'.
unlink :: (MonadProcess r m, MonadIO m) => ProcessId -> m ()
unlink = liftMonadProcess id . unlinkSTM
{-# SPECIALIZE unlink :: ProcessId -> Process r () #-}

monitorSTM :: ProcessId -> ReaderT (ProcessEnv r) STM MonitorRef
monitorSTM !pid = do
  thisProcess <- reader processEnvProcessContext
  mid <- newMonitorRefId
  let ref = MonitorRef mid pid (processContextId thisProcess)
  withReaderT processEnvNodeContext (lookupProcess pid) >>= \case
    Nothing -> lift $ do
      let down = Down ref pid (Just $ toException $ NoProc pid)
      sendLazySTM thisProcess down
    Just pc -> lift $ do
      Set.insert ref (processContextMonitors pc)
      Set.insert ref (processContextMonitorees thisProcess)
  pure ref
  where
    newMonitorRefId = withReaderT processEnvNodeContext $ do
      c <- readTVarR nodeContextNextMonitorRefId
      writeTVarR nodeContextNextMonitorRefId $!! succMonitorRefId c
      pure c

-- | Monitor another process.
--
-- When the monitored process stops (or doesn't exist in the first place), a
-- 'Down' message is sent to this process' mailbox.
monitor :: (MonadProcess r m, MonadIO m) => ProcessId -> m MonitorRef
monitor = liftMonadProcess id . monitorSTM
{-# SPECIALIZE monitor :: ProcessId -> Process r MonitorRef #-}

-- | Options for the 'demonitor' action.
data DemonitorOption
  = -- | Remove any 'Down' messages for the given 'MonitorRef' from the
    -- process mailbox before returning.
    DemonitorFlush
  deriving (Show, Eq)

newtype InvariantViolation = InvariantViolation String
  deriving (Show)

instance Exception InvariantViolation where
  displayException (InvariantViolation s) = "Invariant violation: " <> s

demonitorSTM :: MonitorRef -> ReaderT (ProcessEnv r) STM ()
demonitorSTM !ref = do
  thisProcess <- reader processEnvProcessContext
  if monitorRefMonitor ref /= processContextId thisProcess
    then lift $ throwSTM (InvalidMonitorRef ref)
    else
      withReaderT processEnvNodeContext (lookupProcess $ monitorRefMonitoree ref) >>= \case
        Nothing -> lift $ do
          -- Process no longer exists, hence, the ref should no longer
          -- be in the tracking sets, otherwise, there's a bug.
          Set.lookup ref (processContextMonitorees thisProcess) >>= \case
            True -> throwSTM $ InvariantViolation "demonitorSTM: ref in monitorees, but monitor gone"
            False -> pure ()
        Just pc -> lift $ do
          Set.delete ref (processContextMonitors pc)
          Set.delete ref (processContextMonitorees thisProcess)

-- | Cancel a 'MonitorRef'.
--
-- Keep in mind a 'Down' message could have been delivered before (or while)
-- 'demonitor' is called, hence such message could be found in the mailbox
-- after calling 'demonitor', unless the 'DemonitorFlush' option is used.
--
-- Note: this throws an 'InvalidMonitorRef' exception when called with a
-- 'MonitorRef' created from a call to 'monitor' from another process.
--
-- See 'monitor'.
demonitor :: (MonadProcess r m, MonadIO m) => [DemonitorOption] -> MonitorRef -> m ()
demonitor !options !ref = do
  liftMonadProcess id $ demonitorSTM ref
  when (DemonitorFlush `elem` options) $ do
    receive
      [ matchIf (\d -> downMonitorRef d == ref) (\_ -> pure ()),
        after 0 (pure ())
      ]
{-# SPECIALIZE demonitor :: [DemonitorOption] -> MonitorRef -> Process r () #-}

exitSTM :: (Exception e) => ProcessId -> Maybe e -> ReaderT (ProcessEnv r) STM ()
exitSTM !pid !exc = do
  thisProcess <- reader (processContextId . processEnvProcessContext)
  withReaderT processEnvNodeContext (lookupProcess pid) >>= \case
    Nothing -> pure () -- Process doesn't (or no longer) exists
    Just pc -> case fmap toException exc of
      Nothing ->
        lift (readTVar $ processContextTrapExit pc) >>= \case
          False -> pure ()
          True -> lift $ do
            let msg = Exit thisProcess pid False (fmap toException exc)
             in sendLazySTM pc msg
      Just exc' ->
        if isKill exc'
          then lift $ deliverException pc exc'
          else
            lift (readTVar $ processContextTrapExit pc) >>= \case
              False -> lift $ deliverException pc exc'
              True -> lift $ do
                let msg = Exit thisProcess pid False (Just exc')
                 in sendLazySTM pc msg

-- | Request or force a process to exit.
--
-- - When the target process does not trap exits (see 'TrapExit') and no
-- exception is provided, this is a no-op.
-- - When the target process does not trap exits (see 'TrapExit') and an
--  exception is provided, the exception will be raised in the target process.
-- - When the target process traps exits (see 'TrapExit'), an 'Exit' message
--  will be delivered to the target process with 'exitLink' set to 'False', and
-- 'exitReason' to the given exception (or 'Nothing'), unless the exception is a
-- 'Kill'.
--
-- If a 'Kill' exception is provided, it is raised in the target process, even
-- if said process is trapping exceptions (see 'Troupe.kill').
--
-- Unlike the behaviour in Erlang, there's no difference between calling 'exit'
-- with the 'ProcessId' of the calling process itself or any other process.
exit :: (MonadProcess r m, MonadIO m, Exception e) => ProcessId -> Maybe e -> m ()
exit !pid !exc = liftMonadProcess id $ exitSTM pid exc
{-# SPECIALIZE exit :: (Exception e) => ProcessId -> Maybe e -> Process r () #-}

-- | Check whether a process with given 'ProcessId' is alive.
--
-- Note this could return 'True' even though the process is no longer alive
-- by the time this function returns. The inverse, where a process is deemed
-- not to be alive (as returned by this function), but then is alive anyway by
-- the time the function returns, is unlikely but should be considered possible
-- as well.
isProcessAlive :: (MonadProcess r m, MonadIO m) => ProcessId -> m Bool
isProcessAlive !pid =
  liftMonadProcess processEnvNodeContext $
    isJust <$> lookupProcess pid
{-# SPECIALIZE isProcessAlive :: ProcessId -> Process r Bool #-}

-- | 'WithMonitor' defines how a process is monitored.
data WithMonitor r where
  -- | The process is started with a monitor.
  WithMonitor :: WithMonitor (ProcessId, MonitorRef)
  -- | The process is started without a monitor.
  WithoutMonitor :: WithMonitor ProcessId

-- | Process spawn options.
--
-- See 'spawnWithOptions'.
data SpawnOptions r = SpawnOptions
  { -- | Link the process.
    spawnOptionsLink :: !Bool,
    -- | Optionally monitor the process.
    spawnOptionsMonitor :: !(WithMonitor r),
    -- | Process thread affinity.
    spawnOptionsAffinity :: !ThreadAffinity
  }

-- Copied from ki

-- | What, if anything, a process is bound to.
data ThreadAffinity
  = -- | Unbound.
    Unbound
  | -- | Bound to a capability.
    Capability Int
  deriving stock (Eq, Show)

-- | The low-level spawn that takes an additional options argument.
--
-- 'Troupe.spawn', 'Troupe.spawnLink' and 'Troupe.spawnMonitor' are specialized
-- versions of this function.
spawnWithOptions :: (MonadProcess r m, MonadIO m) => SpawnOptions t -> Process r a -> m t
spawnWithOptions !options process = do
  let cb pid = do
        when (spawnOptionsLink options) $
          linkSTM pid
        case spawnOptionsMonitor options of
          WithoutMonitor -> pure pid
          WithMonitor -> do
            ref <- monitorSTM pid
            pure (pid, ref)

  spawnImpl (spawnOptionsAffinity options) cb process
{-# SPECIALIZE spawnWithOptions :: SpawnOptions t -> Process r a -> Process r t #-}

data SendOptions = SendOptions

sendWithOptions :: (MonadProcess r m, MonadIO m, Typeable a) => SendOptions -> ProcessId -> a -> m ()
sendWithOptions SendOptions !pid a = do
  env <- processEnvNodeContext <$> getProcessEnv
  liftIO $
    atomically $
      runReaderT (lookupProcess pid) env >>= \case
        Nothing -> pure ()
        Just pc -> sendLazySTM pc a
{-# SPECIALIZE sendWithOptions :: (Typeable a) => SendOptions -> ProcessId -> a -> Process r () #-}

-- | Send a message to a process' mailbox.
--
-- The message is fully evaluated (using 'deepseq') in the current process
-- before delivering it.
send :: (MonadProcess r m, MonadIO m, Typeable a, NFData a) => ProcessId -> a -> m ()
send !pid !a = a `deepseq` sendWithOptions SendOptions pid a
{-# INLINE send #-}
{-# SPECIALIZE send :: (Typeable a, NFData a) => ProcessId -> a -> Process r () #-}

-- | Send a message to a process' mailbox.
--
-- The message is not fully evaulated before delivering it, hence, if
-- evaluation requires large computations, or fails, this will be observed
-- in the receiving process.
--
-- In general, prefer using 'send' and provide an 'NFData' instance of
-- message types.
sendLazy :: (MonadProcess r m, MonadIO m, Typeable a) => ProcessId -> a -> m ()
sendLazy = sendWithOptions SendOptions
{-# INLINE sendLazy #-}
{-# SPECIALIZE sendLazy :: (Typeable a) => ProcessId -> a -> Process r () #-}

data ReceiveOptions = ReceiveOptions

-- | Matching clause for a value of type @a@ in monadic context @m@.
data Match m a
  = MatchMessage (Dynamic -> Maybe (m a))
  | MatchAfter Int (m a)
  deriving (Functor)

receiveWithOptions :: (MonadProcess r m, MonadIO m) => ReceiveOptions -> [Match m a] -> m a
receiveWithOptions ReceiveOptions !matches = do
  queue <- processContextQueue . processEnvProcessContext <$> getProcessEnv

  p <- liftIO $ do
    matches' <- forM matches $ \case
      MatchMessage fn -> pure (MatchMsg fn)
      MatchAfter t ma -> case t of
        0 -> pure $ MatchChan $ pure ma
        t' -> do
          tv <- registerDelay t'
          pure $ MatchChan $ do
            v <- readTVar tv
            check v
            pure ma

    dequeue queue Blocking matches'

  ensureSignalsDelivered

  case p of
    Nothing -> error "receiveWithOptions: dequeue returned Nothing"
    Just ma -> ma
  where
    ensureSignalsDelivered = do
      exceptions <- processContextExceptions . processEnvProcessContext <$> getProcessEnv
      liftIO $ atomically $ do
        e <- isEmptyTQueue exceptions
        check e
{-# SPECIALIZE receiveWithOptions :: ReceiveOptions -> [Match (Process r) a] -> Process r a #-}

-- | Receive some message from the process mailbox, blocking.
receive :: (MonadProcess r m, MonadIO m) => [Match m a] -> m a
receive !matches = receiveWithOptions ReceiveOptions matches
{-# INLINE receive #-}
{-# SPECIALIZE receive :: [Match (Process r) a] -> Process r a #-}

-- | Match any message meeting some predicate of a specific type.
matchIf :: (Typeable a) => (a -> Bool) -> (a -> m b) -> Match m b
matchIf predicate handle = MatchMessage $ \dyn -> case fromDynamic dyn of
  Nothing -> Nothing
  Just a -> if predicate a then Just (handle a) else Nothing
{-# INLINE matchIf #-}

-- | A 'Match' which doesn't receive any messages, but fires after a given
-- amount of time.
--
-- Instead of looking for a message in the process' mailbox, an 'after' clause
-- in a call to 'receive' will fire after a given number of microseconds,
-- yielding the provided monadic value. This can be used to implement receiving
-- messages with a timeout.
--
-- When the given timeout is @0@, the 'receive' call will be non-blocking.
-- Note, however, the order of matches is important, so
--
-- @
-- s <- self
-- send s ()
-- receive [after 0 (pure "timeout"), match (\() -> pure "message")]
-- @
--
-- will always return @"timeout"@, whilst
--
-- @
-- s <- self
-- send s ()
-- receive [match (\() -> pure "message"), after 0 (pure "timeout")]
-- @
--
-- will always return @"message"@.
--
-- In general, @'after'@ should be the last 'Match' passed to 'receive'.
after ::
  -- | Timeout in microseconds. Use @0@ for a non-blocking 'receive'.
  Int ->
  -- | Action to call when the timeout expired.
  m a ->
  Match m a
after = MatchAfter
{-# INLINE after #-}

spawnImpl :: (MonadProcess r m, MonadIO m) => ThreadAffinity -> (ProcessId -> ReaderT (ProcessEnv r) STM t) -> Process r a -> m t
spawnImpl affinity cb process = do
  currentEnv <- getProcessEnv

  liftIO $ do
    processContext <- newProcessContext (processEnvNodeContext currentEnv)
    let processEnv = currentEnv {processEnvProcessContext = processContext}

    m <- newEmptyTMVarIO

    bracketOnError
      (run currentEnv processEnv m)
      uninterruptibleCancel
      (wrapup m)
  where
    run currentEnv processEnv m = mask_ $ async $ do
      c <- newEmptyTMVarIO
      let act restore = atomically (readTMVar c) >>= \() -> restore (runProcess process processEnv)

      let withAffinity = case affinity of
            Unbound -> withAsyncWithUnmask act
            Capability n -> withAsyncOnWithUnmask n act

      withAffinity $ \a -> do
        let pid = processContextId (processEnvProcessContext processEnv)

        -- 1. Register the process on the node, calculate the result value of `spawnImpl`, and
        -- let the process actually run
        let register = atomically $ do
              registerProcess (processEnvNodeContext processEnv) (processEnvProcessContext processEnv)
              r <- runReaderT (cb pid) currentEnv
              writeTMVar c ()
              writeTMVar m r

        -- 2. Wait for either the process thread to return (successfully or with an exception,
        -- don't really care at this point), or an exception to be delivered to the process
        -- to be set.
        -- In the second case, cancel the `Async` with said exception.
        let wait = atomically $ do
              Left <$> waitCatchSTM a
                <|> Right <$> readTQueue (processContextExceptions $ processEnvProcessContext processEnv)

            loop =
              wait >>= \case
                Left _ -> pure ()
                Right exc -> do
                  uninterruptibleThrowTo a exc
                  loop

        -- 3. At this point, either the `Async` already returned, or we canceled it.
        -- Wait for it again (this should not actually block, since we know it has exited
        -- already at this point), and perform whichever effects are supposed to happen,
        -- including unregistering the process, removing the process as a monitor from its
        -- monitorees, notify all its monitors, and deliver signals or messages to linked
        -- processes (also, removing the link).
        let cleanup = atomically $ flip runReaderT processEnv $ do
              res <-
                lift (waitCatchSTM a) >>= \case
                  Left exn -> pure (Just exn)
                  Right _ -> pure Nothing

              unregisterProcess pid
              handleMonitorees
              handleMonitors pid res
              handleLinks pid res

        ( (register >>= \() -> loop)
            `withException` \e ->
              uninterruptibleThrowTo a (e :: SomeException)
          )
          `finally` cleanup

    -- Like uninterruptibleCancel, but with a custom exception
    uninterruptibleThrowTo a e =
      uninterruptibleMask_ $
        throwTo (asyncThreadId a) e

    registerProcess nodeContext processContext =
      Map.insert processContext (processContextId processContext) (nodeContextProcesses nodeContext)

    unregisterProcess pid =
      reader (nodeContextProcesses . processEnvNodeContext) >>= lift . Map.delete pid

    handleMonitorees = do
      monitorees <- reader (processContextMonitorees . processEnvProcessContext)
      nodeContext <- reader processEnvNodeContext
      lift $ forM_ (Set.unfoldlM monitorees) $ \ref -> do
        runReaderT (lookupProcess (monitorRefMonitoree ref)) nodeContext >>= \case
          Nothing -> throwSTM $ InvariantViolation "spawnImpl: monitoree doesn't exist"
          Just pc -> do
            Set.delete ref (processContextMonitors pc)

    handleMonitors pid res = do
      monitors <- reader (processContextMonitors . processEnvProcessContext)
      nodeContext <- reader processEnvNodeContext
      lift $ forM_ (Set.unfoldlM monitors) $ \ref -> do
        runReaderT (lookupProcess (monitorRefMonitor ref)) nodeContext >>= \case
          Nothing -> throwSTM $ InvariantViolation "spawnImpl: monitor doesn't exist"
          Just pc -> do
            Set.delete ref (processContextMonitorees pc)
            let down = Down ref pid (fmap convertKillToKilled res)
            sendLazySTM pc down

    handleLinks linkee res = do
      links <- reader (processContextLinks . processEnvProcessContext)
      nodeContext <- reader processEnvNodeContext
      lift $ forM_ (Set.unfoldlM links) $ \pid2 -> do
        runReaderT (lookupProcess pid2) nodeContext >>= \case
          Nothing -> throwSTM $ InvariantViolation "spawnImpl: linkee doesn't exist"
          Just pc -> do
            let exc = Exit linkee pid2 True res
            Set.delete linkee (processContextLinks pc)
            deliverExit pc exc

    wrapup m a = do
      res <- atomically $ (Left <$> waitCatchSTM a) <|> (Right <$> readTMVar m)
      case res of
        Left l -> case l of
          Left exc -> throwM exc
          Right () -> do
            -- A case where `a` returned successfully (i.e., process exited), and
            -- this was noticed before we could read out `m` (ordering of the `<|>`
            -- clause above). However, we know from the implementation above, that
            -- if `a` returned successfully, `m` must be filled.
            atomically (tryReadTMVar m) >>= \case
              Nothing -> throwM $ InvariantViolation "spawnImpl: impossible case, Async returned but TMVar empty"
              Just t -> pure t
        Right t -> pure t
{-# SPECIALIZE spawnImpl :: ThreadAffinity -> (ProcessId -> ReaderT (ProcessEnv r) STM t) -> Process r a -> Process r t #-}
