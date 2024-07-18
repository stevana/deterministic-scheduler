module ManagedThread2 where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.IORef
import Data.List
import System.Random
import System.Timeout

------------------------------------------------------------------------

-- start snippet Signal
data Signal = SingleThreaded | MultiThreaded (TMVar ())
  deriving Eq
-- end snippet

-- start snippet newSignal
newSingleThreadedSignal :: Signal
newSingleThreadedSignal = SingleThreaded

newMultiThreadedSignal :: IO Signal
newMultiThreadedSignal = MultiThreaded <$> newEmptyTMVarIO
-- end snippet

pause :: Signal -> IO ()
pause SingleThreaded        = return ()
pause (MultiThreaded tmvar) = atomically (takeTMVar tmvar)

unpause :: Signal -> IO ()
unpause SingleThreaded        = error
  "unpause: a single thread should never be paused"
unpause (MultiThreaded tmvar) = atomically (putTMVar tmvar ())

isPaused :: Signal -> STM Bool
isPaused SingleThreaded        = return False
isPaused (MultiThreaded tmvar) = isEmptyTMVar tmvar

waitUntilAllPaused :: [Signal] -> IO ()
waitUntilAllPaused signals = atomically $ do
  bs <- mapM isPaused signals
  guard (and bs)

------------------------------------------------------------------------

data ManagedThreadId a = ManagedThreadId
  { _mtidName   :: String
  , _mtidSignal :: Signal
  , _mtidAsync  :: Async a
  }
  deriving Eq

spawn :: String -> (Signal -> IO a) -> IO (ManagedThreadId a)
spawn name io = do
  s <- newMultiThreadedSignal
  a <- async (io s)
  return (ManagedThreadId name s a)

data ThreadStatus a = Paused | Finished a | Threw SomeException

getThreadStatus :: ManagedThreadId a -> IO (ThreadStatus a)
getThreadStatus mtid = atomically go
  where
    go = do
      res <- pollSTM (_mtidAsync mtid)
      case res of
        Nothing -> do
          b <- isPaused (_mtidSignal mtid)
          if b
          then return Paused
          else go
        Just (Left err) -> return (Threw err)
        Just (Right x)  -> return (Finished x)

-- Wait until all threads are paused, then step one of them and wait until it
-- either pauses again or finishes. If it pauses again, then repeat the
-- stepping. If it finishes, remove it from the list of stepped threads and
-- continue stepping.
schedule :: RandomGen g => [ManagedThreadId a] -> g -> IO ([a], g)
schedule mtids0 gen0 = do
  res <- timeout 1000000 (waitUntilAllPaused (map _mtidSignal mtids0))
  case res of
    Nothing -> error "schedule: all threads didn't pause within a second"
    Just () -> do
      -- putStrLn "all paused"
      go mtids0 gen0 []
  where
    go :: RandomGen g => [ManagedThreadId a] -> g -> [a] -> IO ([a], g)
    go []    gen acc = return (reverse acc, gen)
    go mtids gen acc = do
      let (ix, gen') = randomR (0, length mtids - 1) gen
          mtid = mtids !! ix
      -- putStrLn ("schedule, picked: " ++ _mtidName mtid)
      unpause (_mtidSignal mtid)
      status <- getThreadStatus mtid
      case status of
        Finished x -> do
          -- putStrLn ("schedule, finished: " ++ _mtidName mtid)
          go (mtids \\ [mtid]) gen' (x : acc)
        Paused     -> go mtids gen' acc
        Threw err  -> error ("schedule: " ++ show err)

mapConcurrently :: RandomGen g => (Signal -> a -> IO b) -> [a] -> g -> IO ([b], g)
mapConcurrently f xs gen = do
  mtids <- forM (zip [0..] xs) $ \(i, x) ->
    spawn ("Thread " ++ show i) (\sig -> f sig x)
  schedule mtids gen

------------------------------------------------------------------------

data SharedMemory a = SharedMemory
  { memReadIORef  :: IORef a -> IO a
  , memWriteIORef :: IORef a -> a -> IO ()
  }

realMem :: SharedMemory a
realMem = SharedMemory readIORef writeIORef

fakeMem :: Signal -> SharedMemory a
fakeMem signal =
  SharedMemory
    { memReadIORef = \ref -> do
        pause signal
        -- putStrLn "reading ref"
        x <- readIORef ref
        -- pause signal
        return x
    , memWriteIORef = \ref x -> do
        pause signal
        -- putStrLn "writing ref"
        writeIORef ref x
        -- pause signal
    }

------------------------------------------------------------------------

data AtomicCounter = AtomicCounter (IORef Int)

newCounter :: IO AtomicCounter
newCounter = do
  ref <- newIORef 0
  return (AtomicCounter ref)

incr :: SharedMemory Int -> AtomicCounter -> IO ()
incr mem (AtomicCounter ref) = do
  i <- memReadIORef mem ref
  memWriteIORef mem ref (i + 1)

get :: SharedMemory Int -> AtomicCounter -> IO Int
get mem (AtomicCounter ref) = memReadIORef mem ref

------------------------------------------------------------------------

test' :: Int -> IO (Int, Bool, Int)
test' seed = do
  counter <- newCounter
  mtid1 <- spawn "0" (\signal -> incr (fakeMem signal) counter)
  mtid2 <- spawn "1" (\signal -> incr (fakeMem signal) counter)
  let gen  = mkStdGen seed
  putStrLn "starting scheduler"
  _ <- schedule [mtid1, mtid2] gen
  two <- get realMem counter
  return (seed, two == 2, two)

test2 :: IO ()
test2 = mapM_ (\seed -> print =<< test' seed) [0..0]
