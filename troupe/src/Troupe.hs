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

    -- ** Exchanging messages between processes
    send,
    sendLazy,
    receive,
    receiveTimeout,
    expect,
    Match,
    match,
    matchIf,

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
  )
where

import Control.Concurrent.STM (atomically, check)
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
    NodeContext (..),
    Process,
    ProcessEnv (..),
    ProcessOption (..),
    demonitor,
    exit,
    expect,
    getProcessOption,
    isProcessAlive,
    link,
    match,
    matchIf,
    monitor,
    newNodeContext,
    newProcessContext,
    receive,
    receiveTimeout,
    runProcess,
    self,
    send,
    sendLazy,
    setProcessOption,
    spawn,
    spawnLink,
    spawnMonitor,
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
  nodeContext <- newNodeContext r
  processContext <- newProcessContext nodeContext
  let processEnv = ProcessEnv nodeContext processContext

  _ <- runProcess (spawn process) processEnv

  atomically $ do
    cnt <- Map.size (nodeContextProcesses nodeContext)
    check (cnt == 0)

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
