{-# LANGUAGE PatternSynonyms #-}

-- | Core functionality of the @troupe@ library.
module Troupe
  ( -- * Main entrypoint
    runNode,

    -- * Processes
    Process,
    ProcessId,

    -- ** Spawning processes
    spawn,
    spawnLink,
    spawnMonitor,

    -- *** Spawning processes with options
    spawnWithOptions,
    SpawnOptions (..),
    ThreadAffinity (..),
    WithMonitor (..),

    -- ** Exchanging messages between processes
    send,
    sendLazy,
    receive,
    expect,
    Match,
    match,
    matchIf,
    after,

    -- ** Linking and monitoring processes
    link,
    unlink,
    MonitorRef,
    monitor,
    DemonitorOption (..),
    demonitor,

    -- ** Querying the process table
    isProcessAlive,

    -- ** Killing processes
    exit,

    -- ** Process-local actions
    self,
    ProcessOption (..),
    setProcessOption,
    getProcessOption,

    -- * Built-in messages and signals
    NoProc (..),
    isNoProc,
    pattern IsNoProc,
    InvalidMonitorRef (..),
    isInvalidMonitorRef,
    pattern IsInvalidMonitorRef,
    Down (..),
    Exit (..),
    isExit,
    pattern IsExit,
    kill,
    Killed (..),
    isKilled,
    pattern IsKilled,

    -- * @mtl@-style transformer support
    MonadProcess (..),
    withProcessEnv
  )
where

import Control.Concurrent.STM (atomically, check)
import Control.Monad.IO.Class (MonadIO)
import Data.Typeable (Typeable)
import qualified StmContainers.Map as Map
import Troupe.Exceptions
  ( Exit (..),
    InvalidMonitorRef (..),
    Killed (..),
    NoProc (..),
    isExit,
    isInvalidMonitorRef,
    isKilled,
    isNoProc,
    kill,
    pattern IsExit,
    pattern IsInvalidMonitorRef,
    pattern IsKilled,
    pattern IsNoProc,
  )
import Troupe.Process
  ( DemonitorOption (..),
    Match,
    MonadProcess (..),
    withProcessEnv,
    NodeContext (..),
    Process,
    ProcessEnv (..),
    ProcessOption (..),
    SpawnOptions (..),
    ThreadAffinity (..),
    WithMonitor (..),
    after,
    demonitor,
    exit,
    getProcessOption,
    isProcessAlive,
    link,
    matchIf,
    monitor,
    newNodeContext,
    newProcessContext,
    receive,
    runProcess,
    self,
    send,
    sendLazy,
    setProcessOption,
    spawnWithOptions,
    unlink,
  )
import Troupe.Types (Down (..), MonitorRef, ProcessId)

-- | Main entrypoint to launch a root 'Process'
--
-- This will run the given 'Process', with the given @r@ available in
-- the 'Control.Monad.Reader.Class.MonadReader' environment of this 'Process',
-- or any 'Process' spawned from it (and so on).
--
-- This blocks as long as some 'Process' is running, hence, @runNode r p@
-- doesn't necessarily return when @p@ returns.
runNode :: r -> Process r a -> IO ()
runNode r process = do
  nodeContext <- newNodeContext
  processContext <- newProcessContext nodeContext
  let processEnv = ProcessEnv nodeContext processContext r

  _ <- runProcess (spawn process) processEnv

  atomically $ do
    cnt <- Map.size (nodeContextProcesses nodeContext)
    check (cnt == 0)

-- | Spawn a new process.
spawn :: (MonadProcess r m, MonadIO m) => Process r a -> m ProcessId
spawn = spawnWithOptions options
  where
    options =
      SpawnOptions
        { spawnOptionsLink = False,
          spawnOptionsMonitor = WithoutMonitor,
          spawnOptionsAffinity = Unbound
        }
{-# INLINE spawn #-}
{-# SPECIALIZE spawn :: Process r a -> Process r ProcessId #-}

-- | Spawn a new process, and atomically 'link' to it.
--
-- See 'spawn' and 'link'.
spawnLink :: (MonadProcess r m, MonadIO m) => Process r a -> m ProcessId
spawnLink = spawnWithOptions options
  where
    options =
      SpawnOptions
        { spawnOptionsLink = True,
          spawnOptionsMonitor = WithoutMonitor,
          spawnOptionsAffinity = Unbound
        }
{-# INLINE spawnLink #-}
{-# SPECIALIZE spawnLink :: Process r a -> Process r ProcessId #-}

-- | Spawn a new process, and atomically 'monitor' it.
--
-- See 'spawn' and 'monitor'.
spawnMonitor :: (MonadProcess r m, MonadIO m) => Process r a -> m (ProcessId, MonitorRef)
spawnMonitor = spawnWithOptions options
  where
    options =
      SpawnOptions
        { spawnOptionsLink = False,
          spawnOptionsMonitor = WithMonitor,
          spawnOptionsAffinity = Unbound
        }
{-# INLINE spawnMonitor #-}
{-# SPECIALIZE spawnMonitor :: Process r a -> Process r (ProcessId, MonitorRef) #-}

-- | Utility to 'receive' a value of a specific type.
expect :: (MonadProcess r m, MonadIO m, Typeable a) => m a
expect = receive [match pure]
{-# INLINE expect #-}
{-# SPECIALIZE expect :: (Typeable a) => Process r a #-}

-- | Match any message of a specific type.
match :: (Typeable a) => (a -> m b) -> Match m b
match = matchIf (const True)
{-# INLINE match #-}

{-
-- alias
-- cancel_timer
-- group_leader?
-- halt
-- hibernate?
-- make_ref ?
-- monitor/3
-- process_flag/3
-- process_info
-- processes
-- read_timer
-- register
-- registered
-- resume_process
-- send_after
-- send_nosuspend
-- ...

-}
