{-# LANGUAGE DeriveFunctor #-}

module Troupe.Queue (newQueue, enqueue, dequeue) where

import Control.Concurrent.Classy.STM (MonadSTM, TQueue, TVar, flushTQueue, modifyTVar', newTQueue, newTVar, writeTQueue)
import Control.Monad.Conc.Class (MonadConc, STM, atomically)

data Queue stm a = Queue
  { queueTQueue :: {-# UNPACK #-} !(TQueue stm a),
    queueMessages :: {-# UNPACK #-} !(TVar stm [a])
  }

newQueue :: (MonadSTM stm) => stm (Queue stm a)
newQueue =
  Queue
    <$> newTQueue
    <*> newTVar []

enqueue :: (MonadSTM stm) => Queue stm a -> a -> stm ()
enqueue queue a = writeTQueue (queueTQueue queue) a

data Match stm m a
  = MatchMessage (m -> Maybe a)
  | MatchSTM (stm a)
  deriving (Functor)

dequeue :: (MonadConc m) => Queue (STM m) a -> [Match (STM m) m' a] -> m (Maybe a)
dequeue queue matches = do
  atomically getMessages
  atomically handleMatches
  where
    getMessages = do
      newMessages <- flushTQueue (queueTQueue queue)
      modifyTVar' (queueMessages queue) (\old -> old ++ newMessages)
