{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE Strict #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}

module Troupe.Exceptions
  ( NoProc (..),
    isNoProc,
    pattern IsNoProc,
    InvalidMonitorRef (..),
    isInvalidMonitorRef,
    pattern IsInvalidMonitorRef,
    Exit (..),
    isExit,
    pattern IsExit,
    Kill (..),
    isKill,
    kill,
    Killed (..),
    isKilled,
    pattern IsKilled,
  )
where

import Control.DeepSeq (NFData (..), ($!!))
import Control.Exception.Base
  ( Exception (..),
    SomeException,
    asyncExceptionFromException,
    asyncExceptionToException,
  )
import GHC.Generics (Generic)
import Troupe.Types (MonitorRef, ProcessId)

-- | Exception delivered when a non-existing 'ProcessId' is used.
newtype NoProc = NoProc ProcessId
  deriving stock (Show, Eq, Ord)
  deriving newtype (NFData)

instance Exception NoProc where
  fromException = asyncExceptionFromException
  toException = asyncExceptionToException
  displayException (NoProc pid) = "No such process: " <> show pid

-- | Predicate on 'NoProc' exceptions.
isNoProc :: SomeException -> Bool
isNoProc exc = case fromException exc of
  Just NoProc {} -> True
  Nothing -> False

-- | Pattern match on 'NoProc' exceptions from 'SomeException'.
pattern IsNoProc :: SomeException
pattern IsNoProc <- (isNoProc -> True)

-- | Exception delivered when an invalid 'MonitorRef' is used, e.g.,
-- when 'Troupe.demonitor'ing a 'MonitorRef' owned by another process.
newtype InvalidMonitorRef = InvalidMonitorRef MonitorRef
  deriving stock (Show, Eq, Ord)
  deriving newtype (NFData)

instance Exception InvalidMonitorRef where
  fromException = asyncExceptionFromException
  toException = asyncExceptionToException
  displayException (InvalidMonitorRef ref) = "Invalid MonitorRef: " <> show ref

-- | Predicate on 'InvalidMonitorRef' exceptions.
isInvalidMonitorRef :: SomeException -> Bool
isInvalidMonitorRef exc = case fromException exc of
  Just InvalidMonitorRef {} -> True
  Nothing -> False

-- | Pattern match on 'InvalidMonitorRef' exceptions from 'SomeException'.
pattern IsInvalidMonitorRef :: SomeException
pattern IsInvalidMonitorRef <- (isInvalidMonitorRef -> True)

-- | Exception raised when a 'Troupe.link'ed process stops (either successfully
-- or with some exception), or delivered as a message when 'Troupe.TrapExit' is
-- set for the receiving process.
data Exit = Exit
  { -- | 'ProcessId' of the process which stopped.
    exitSender :: {-# UNPACK #-} !ProcessId,
    -- | 'ProcessId' of the process to which this message or signal is delivered.
    exitReceiver :: {-# UNPACK #-} !ProcessId,
    -- | This message or signal is delivered because of a 'Troupe.link' between
    -- both processes.
    exitLink :: !Bool,
    -- | Reason for the process to stop. 'Nothing' ifsuccessful, @'Just' e@ when
    -- stopped with some exception.
    exitReason :: !(Maybe SomeException)
  }
  deriving (Show)

instance Exception Exit where
  fromException = asyncExceptionFromException
  toException = asyncExceptionToException

-- | Predicate on 'Exit' exceptions.
isExit :: SomeException -> Bool
isExit exc = case fromException exc of
  Just Exit {} -> True
  Nothing -> False

-- | Pattern match on 'Exit' exceptions from 'SomeException'.
pattern IsExit :: SomeException
pattern IsExit <- (isExit -> True)

-- | Exception raised to forcibly kill a process.
--
-- Since the type is not exported (from "Troupe"), there's no way to match
-- on it, and hence catch it (except when catching 'SomeException', which
-- should be avoided).
newtype Kill = Kill String
  deriving (Show, Eq)

instance Exception Kill where
  fromException = asyncExceptionFromException
  toException = asyncExceptionToException
  displayException (Kill msg) = "Kill: " <> msg

instance NFData Kill where
  rnf (Kill msg) = rnf msg

isKill :: SomeException -> Bool
isKill exc = case fromException exc of
  Just Kill {} -> True
  Nothing -> False

-- | Construct a 'Kill' exception given some message.
--
-- This exception can't be caught inside a process (unless catching
-- 'SomeException'), hence, @'Troupe.exit' pid (Just $ 'kill' message)@
-- will effectively cause a process to exit. Linked processes and monitors
-- are notified of this using the standard mechanisms, with one caveat:
-- a 'Kill' exception is transformed into a 'Killed' exception (as found
-- in, e.g., 'Troupe.Types.downReason' or 'exitReason') so it can be caught
-- in linked or monitoring processes.
kill :: String -> SomeException
kill !msg = toException $!! Kill msg

-- | Exception used to inform links and monitors of a 'Kill' exception raised
-- by some linked or monitored process.
--
-- See 'kill'.
newtype Killed = Killed String
  deriving (Show, Eq, Generic)
  deriving anyclass (NFData)

instance Exception Killed where
  displayException (Killed msg) = "Killed: " <> msg

-- | Predicate on 'Killed' exceptions.
isKilled :: SomeException -> Bool
isKilled exc = case fromException exc of
  Just Killed {} -> True
  Nothing -> False

-- | Pattern match on 'Killed' exceptions from 'SomeException'.
pattern IsKilled :: SomeException
pattern IsKilled <- (isKilled -> True)
