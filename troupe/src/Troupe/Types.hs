{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Strict #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}

module Troupe.Types
  ( ProcessId,
    processId0,
    succProcessId,
    MonitorRefId,
    monitorRefId0,
    succMonitorRefId,
    MonitorRef (..),
    Down (..),
  )
where

import Control.DeepSeq (NFData (..), deepseq, ($!!))
import Control.Exception.Base (SomeException)
import Data.Hashable (Hashable (..))
import Data.Word (Word64)

-- | Identifier of some process.
newtype ProcessId = ProcessId Word64
  deriving stock (Show, Eq, Ord)
  deriving newtype (Hashable, NFData)

processId0 :: ProcessId
processId0 = ProcessId 0

succProcessId :: ProcessId -> ProcessId
succProcessId (ProcessId p) = ProcessId $!! succ p
{-# INLINE succProcessId #-}

-- | Identifier of a 'MonitorRef'.
newtype MonitorRefId = MonitorRefId Word64
  deriving stock (Show, Eq, Ord)
  deriving newtype (Hashable, NFData)

monitorRefId0 :: MonitorRefId
monitorRefId0 = MonitorRefId 0

succMonitorRefId :: MonitorRefId -> MonitorRefId
succMonitorRefId (MonitorRefId r) = MonitorRefId $!! succ r
{-# INLINE succMonitorRefId #-}

-- | Reference to a monitor on a process.
--
-- See 'Troupe.monitor' and 'Troupe.demonitor'.
data MonitorRef = MonitorRef
  { monitorRefId :: {-# UNPACK #-} !MonitorRefId,
    monitorRefMonitoree :: {-# UNPACK #-} !ProcessId,
    monitorRefMonitor :: {-# UNPACK #-} !ProcessId
  }
  deriving (Show, Eq, Ord)

instance NFData MonitorRef where
  rnf (MonitorRef i e m) = i `deepseq` e `deepseq` m `deepseq` ()

instance Hashable MonitorRef where
  hashWithSalt s (MonitorRef i e m) =
    s
      `hashWithSalt` i
      `hashWithSalt` e
      `hashWithSalt` m

-- | Message delivered when a monitored process stops (either by returning
-- successfully, or because of some exception).
--
-- See 'Troupe.monitor'.
data Down = Down
  { -- | 'MonitorRef' causing this 'Down' message to be delivered.
    downMonitorRef :: {-# UNPACK #-} !MonitorRef,
    -- | 'ProcessId' of the monitored process that stopped.
    downProcessId :: {-# UNPACK #-} !ProcessId,
    -- | Reason for the process to stop. 'Nothing' if successful, @'Just' e@
    -- when stopped with some exception.
    downReason :: !(Maybe SomeException)
  }
  deriving (Show)
