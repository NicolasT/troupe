{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE LambdaCase #-}

module Troupe.Queue
  ( Queue,
    newQueue,
    enqueue,
    Match (..),
    dequeue,
  )
where

import Control.Concurrent.Classy.STM
  ( MonadSTM,
    TQueue,
    TVar,
    flushTQueue,
    modifyTVar',
    newTQueue,
    newTVar,
    orElse,
    readTVar,
    retry,
    tryReadTQueue,
    unGetTQueue,
    writeTQueue,
    writeTVar,
  )
import qualified Control.Concurrent.STM as CCS
import Control.Monad.Conc.Class (MonadConc, STM, atomically)

data Queue stm a = Queue
  { queueTQueue :: {-# UNPACK #-} !(TQueue stm a),
    queueMessages :: !(TVar stm [a])
  }

newQueue :: (MonadSTM stm) => stm (Queue stm a)
newQueue =
  Queue
    <$> newTQueue
    <*> newTVar []
{-# SPECIALIZE newQueue :: CCS.STM (Queue CCS.STM a) #-}

enqueue :: (MonadSTM stm) => Queue stm a -> a -> stm ()
enqueue queue = writeTQueue (queueTQueue queue)
{-# INLINE enqueue #-}
{-# SPECIALIZE enqueue :: Queue CCS.STM a -> a -> CCS.STM () #-}

data Match stm a b
  = MatchMessage (a -> Maybe b)
  | MatchSTM (stm b)
  deriving (Functor)

dequeue :: (MonadConc m) => Queue (STM m) a -> [Match (STM m) a b] -> m b
dequeue queue matches = do
  atomically getMessages
  atomically $
    handleExistingMessages >>= \case
      Nothing -> handleNewMessages
      Just b -> pure b
  where
    getMessages = do
      newMessages <- flushTQueue (queueTQueue queue)
      modifyTVar' (queueMessages queue) (++ newMessages)
    handleExistingMessages = do
      messages <- readTVar (queueMessages queue)
      foldr orElse (pure Nothing) $ flip map matches $ \case
        MatchMessage fn -> findMessage fn [] messages
        MatchSTM stm -> fmap Just stm
    findMessage fn acc = \case
      [] -> retry
      (x : xs) -> case fn x of
        Nothing -> findMessage fn (x : acc) xs
        Just a -> do
          writeTVar (queueMessages queue) (reverse acc ++ xs)
          pure (Just a)
    handleNewMessages = foldr orElse (storeMessage >> retry) $ flip map matches $ \case
      MatchMessage fn ->
        tryReadTQueue (queueTQueue queue) >>= \case
          Nothing -> retry
          Just msg -> case fn msg of
            Nothing -> do
              unGetTQueue (queueTQueue queue) msg
              retry
            Just a -> pure a
      MatchSTM stm -> stm
    storeMessage = do
      mmsg <- tryReadTQueue (queueTQueue queue)
      case mmsg of
        Nothing -> pure ()
        Just msg -> modifyTVar' (queueMessages queue) (\old -> old ++ [msg])
{-# SPECIALIZE dequeue :: Queue CCS.STM a -> [Match CCS.STM a b] -> IO b #-}
