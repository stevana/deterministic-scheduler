{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TypeFamilies #-}

module Example.Counter where

import Control.Monad.Reader
import Data.IORef
import Data.Void
import System.IO.Unsafe
import Test.QuickCheck
import Test.QuickCheck.Monadic

import qualified ManagedThread2 as Scheduler
import Parallel
import Stateful

------------------------------------------------------------------------

gLOBAL_COUNTER :: IORef Int
gLOBAL_COUNTER = unsafePerformIO (newIORef 0)
{-# NOINLINE gLOBAL_COUNTER #-}

incr :: IO ()
incr = atomicModifyIORef' gLOBAL_COUNTER (\n -> (n + 1, ()))

incr42Bug :: IO ()
incr42Bug = atomicModifyIORef' gLOBAL_COUNTER
  (\n -> if n == 42 then (n, ()) else (n + 1, ()))

-- start snippet incrRaceCondition
incrRaceCondition :: Scheduler.SharedMemory Int -> IO ()
incrRaceCondition mem = do
  n <- liftIO (Scheduler.memReadIORef mem gLOBAL_COUNTER)
  Scheduler.memWriteIORef mem gLOBAL_COUNTER (n + 1)
-- end snippet incrRaceCondition

get :: Scheduler.SharedMemory Int -> IO Int
get mem = Scheduler.memReadIORef mem gLOBAL_COUNTER

reset :: IO ()
reset = writeIORef gLOBAL_COUNTER 0

------------------------------------------------------------------------

newtype Counter = Counter Int
  deriving (Eq, Ord, Show)

instance StateModel Counter where

  -- We start counting from zero.
  initialState :: Counter
  initialState = Counter 0

  -- The commands correspond to the names of the functions that operate on the
  -- global counter.
  data Command Counter r
    = Incr
    | Get
    deriving (Show, Functor, Foldable)

  -- The responses correspond to the return types of each function. By
  -- convention we'll add a underscore suffix to a response of the corresponding
  -- command.
  data Response Counter r
    = Incr_ ()
    | Get_ Int
    deriving (Eq, Show, Functor, Foldable)

  -- We'll generate increments and reads of the counter with equal probability.
  generateCommand :: Counter -> Gen (Command Counter r)
  generateCommand _s = elements [Incr, Get]

  -- The fake takes a command and the model of the counter and returns a new
  -- model and a response.
  runFake :: Command Counter r -> Counter -> Either Void (Counter, Response Counter r)
  runFake Incr  (Counter n) = return (Counter (n + 1), Incr_ ())
  runFake Get m@(Counter n) = return (m, Get_ n)

  type CommandMonad Counter = ReaderT Scheduler.Signal IO

  -- We also need to explain which part of the counter API each command
  -- corresponds to.
  -- start snippet runReal
  runReal :: Command Counter r -> ReaderT Scheduler.Signal IO (Response Counter r)
  runReal cmd = do
    sig <- ask
    let mem = Scheduler.fakeMem sig
    case cmd of
      Get  -> liftIO (Get_  <$> get mem)
      Incr -> liftIO (Incr_ <$> incrRaceCondition mem)
  -- end snippet runReal
  -- runReal Incr = Incr_ <$> incr
  -- runReal Incr = Incr_ <$> incr42Bug

  -- This example has no references.
  type Reference Counter = Void

  runCommandMonad _ m sig = runReaderT m sig

prop_counter :: Commands Counter -> Property
prop_counter cmds = monadicIO $ do
  liftIO reset
  runCommands cmds
  assert True

-- start snippet parallel-counter
instance ParallelModel Counter

prop_parallelCounter :: ParallelCommands Counter -> Property
prop_parallelCounter cmds = monadicIO $ do
  run reset
  runParallelCommands cmds
  assert True
-- end snippet parallel-counter
