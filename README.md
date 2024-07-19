# Parallel property-based testing with a deterministic thread scheduler

*Work in progress, please don't share, but do feel free to get
involved!*

This post is about how to write tests that can catch race conditions in
a reproducible way. The approach is programming language agnostic, and
should work in most languages that have a decent multi-threaded story.
It's a white-box testing approach, meaning you will have to modify the
software under test.

## Background

In my previous
[post](https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html),
we had a look at how to mechanically derive parallel tests that can
uncover race conditions from a sequential fake[^1].

One of the nice things about the approach is that it's a black-box
testing technique, i.e. it doesn't require the user to change the
software under test.

One big downside is that because threads will interleave differently
when we rerun the tests, there by potentially causing different
outcomes. This in turn creates problems for the shrinking of failing
test cases[^2].

As a workaround, I suggested that when a race condition is found in the
unmodified code, one could swap the shared memory module for one that
introduces sleeps around the operations. This creates less
non-determinism, because the jitter of each operation will have less of
an impact, and therefore helps shrinking.

This isn't a satisfactory solution, of course, and I left a to do item
to implement a determinstic scheduler, like the authors do in the
[paper](https://www.cse.chalmers.se/~nicsma/papers/finding-race-conditions.pdf)
that first introduced parallel property-based testing.

The idea of the deterministic scheduler is that it should be possible to
rerun a multi-threaded program and get exactly the same interleaving of
threads each time.

The deterministic scheduler from the above mentioned paper is called
PULSE. It was
[supposedly](http://quviq.com/documentation/pulse/index.html) released
under the BSD license, however I've not been able to find it.

PULSE is written in Erlang and the paper uses it to test Erlang code. In
Erlang everything is triggered by message passing, so I think that the
correct way of thinking about what PULSE does is that it acts as a
person-in-the-middle proxy. With other words, an Erlang process doesn't
send a messaged directly to another process, but instead asks the
scheduler to send it to the process. That way all messages go via the
scheduler and it can choose the message order. Note that a seed can be
used to introduce randomness, without introducing non-determinism.

I implemented a proxy scheduler like this in Haskell (using
`distributed-process`, think Haskell trying to be like Erlang) about 6
years
[ago](https://github.com/advancedtelematic/quickcheck-state-machine-distributed#readme),
but I didn't know how to do it in a non-message-passing setting.

I was therefore happy to see that my post inspired matklad to write a
[post](https://matklad.github.io/2023/07/05/properly-testing-concurrent-data-structures.html)
where he shows how he'd do it in a multi-threaded shared memory setting.

In this post I'll port matklad's approach from Rust to Haskell and hook
it up to the parallel property-based testing machinary from my previous
post.

Another difference between matklad and the approach in this post is that
matklad uses an ad-hoc correctness criteria, whereas I follow the
parallel property-based testing paper and use
[linearisability](https://cs.brown.edu/~mph/HerlihyW90/p463-herlihy.pdf).

An ad-hoc criteria can be faster than linearisability checking, but
depending on how complicated your system is, it might be harder to find
one. Linearisability checking on the other hand follows mechanically
(for free) from a sequential (single-threaded) model/fake.

If you know what you are doing, then by all means figure out an ad-hoc
correctness criteria like matklad does. If on the otherhand you haven't
tested much concurrent code before, then I'd recommend starting with the
linearisability checking approach that we are about to describe[^3].

## Motivation and overview

In order to explain what we'd like to do, it's helpful to consider an
example of a race condition.

The text book
[example](https://en.wikipedia.org/wiki/Race_condition#Example) of a
race condition is a counter which is incremented by two threads at the
same time.

One possible interleaving of the two threads that yields the correct
result is the following:

| Time | Thread 1       | Thread 2       |     | Integer value |
|:-----|:---------------|:---------------|:---:|:--------------|
| 0    |                |                |     | 0             |
| 1    | read value     |                |  ←  | 0             |
| 2    | increase value |                |     | 0             |
| 3    | write back     |                |  →  | 1             |
| 4    |                | read value     |  ←  | 1             |
| 5    |                | increase value |     | 1             |
| 6    |                | write back     |  →  | 2             |

However there are other interleavings where one of the threads
overwrites the other thread's increment, yielding an incorrect result:

| Time | Thread 1       | Thread 2       |     | Integer value |
|:-----|:---------------|:---------------|:---:|:--------------|
| 0    |                |                |     | 0             |
| 1    | read value     |                |  ←  | 0             |
| 2    |                | read value     |  ←  | 0             |
| 3    | increase value |                |     | 0             |
| 4    |                | increase value |     | 0             |
| 5    | write back     |                |  →  | 1             |
| 6    |                | write back     |  →  | 1             |

In most programming languages the thread interleaving is
non-deterministic, and so we get irreproducible failures also sometimes
known as "Heisenbugs".

What we'd like to do is to be able to start a program with some token
and if the same token is used then we get the same thread interleaving
and therefore a reproducible result.

The idea, due to matklad, is to insert pauses between each shared memory
operation (the reads and writes), have a scheduler unpause one thread at
the time. The scheduler is parametrised by a seed which is used together
with a pseudorandom number generator which allows it to
deterministically choose which thread to unpause.

In the rest of this post we will port matklad's deterministic scheduler
from Rust to Haskell, hopefully in a way that shows that this can be
done in any other language with decent multi-threaded programming
primitives. Then we'll do a short recap of how parallel property-based
testing works, and finally we'll hook up the deterministic schduler to
the parallel property-based testing machinary.

## Deterministic scheduler

The scheduler needs to be able to communicate with the running threads,
in order to be able to determinstically unpause, or "step", one thread
at a time.

We'll use Haskell's `TMVar`s for this, but any kind of shared memory
will do.

Haskell's `MVar`s can be thought of boxes that contain a value, where
taking something out of a box that is empty blocks and putting something
into a box that is full blocks as well. Where "blocks" means that the
run-time will suspend the thread that tries the blocking action and only
wake it up when the `MVar` changes, i.e. it's an efficient way of
waiting compared to
[busy-waiting](https://en.wikipedia.org/wiki/Busy_waiting) or spinning.

The `T` in `TMVar`s merely adds
[STM](https://en.wikipedia.org/wiki/Software_transactional_memory)
transactions around `MVar`s, we'll see an example of what these are
useful for shortly.

``` haskell
data Signal = SingleThreaded | MultiThreaded (TMVar ())
  deriving Eq
```

``` haskell
newSingleThreadedSignal :: Signal
newSingleThreadedSignal = SingleThreaded

newMultiThreadedSignal :: IO Signal
newMultiThreadedSignal = MultiThreaded <$> newEmptyTMVarIO
```

``` haskell
waitUntilAllPaused :: [Signal] -> IO ()
waitUntilAllPaused signals = atomically $ do
  bs <- mapM isPaused signals
  guard (and bs)
```

``` haskell
data ManagedThreadId a = ManagedThreadId
  { _mtidName   :: String
  , _mtidSignal :: Signal
  , _mtidAsync  :: Async a
  }
  deriving Eq
```

``` haskell
data ManagedThreadId a = ManagedThreadId
  { _mtidName   :: String
  , _mtidSignal :: Signal
  , _mtidAsync  :: Async a
  }
  deriving Eq
```

``` haskell
spawn :: String -> (Signal -> IO a) -> IO (ManagedThreadId a)
spawn name io = do
  s <- newMultiThreadedSignal
  a <- async (io s)
  return (ManagedThreadId name s a)
```

``` haskell
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
```

``` haskell
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
```

``` haskell
mapConcurrently :: RandomGen g => (Signal -> a -> IO b) -> [a] -> g -> IO ([b], g)
mapConcurrently f xs gen = do
  mtids <- forM (zip [0..] xs) $ \(i, x) ->
    spawn ("Thread " ++ show i) (\sig -> f sig x)
  schedule mtids gen
```

``` haskell
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
```

``` haskell
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
```

``` haskell
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
```

## Parallel property-based testing recap

In our counter example above, we had two concurrent increments, in this
case it's easy to see what the answer must be (the counter must have the
value of two, if we start counting from zero and increment by one).

However for more complicated scenarios it gets less clear, consider:

- two concurrent incrs + get
- crashing threads

Luckily there's a correctness criteria for concurrent programs like
these which is based on a sequential model:

Linearizability: a correctness condition for concurrent objects by
Herlihy and Wing (1990)
<https://cs.brown.edu/~mph/HerlihyW90/p463-herlihy.pdf>

this is what we use in parallel property-based testing (and also what
Jepsen's Knossos checker uses)

The idea in a nutshell: execute commands in parallel, collect a
concurrent history of when each command started and stopped executing,
try to find an interleaving of commands which satisfies the sequential
model.

## Integrating the scheduler into the testing

I don't want to reimplement the parallel property-based testing
machinary from my previous post here, but merely show that integrating
the deterministic scheduler isn't too much work.

### Changes to sequential module

``` diff
--- ../stateful-pbt-with-fakes/src/Stateful.hs  2024-06-20 09:02:07.618238490 +0200
+++ src/Stateful.hs 2024-07-11 06:59:12.547433661 +0200
@@ -2,9 +2,10 @@
 {-# LANGUAGE DerivingStrategies #-}
 {-# LANGUAGE FlexibleContexts #-}
 {-# LANGUAGE InstanceSigs #-}
+{-# LANGUAGE Rank2Types #-}
 {-# LANGUAGE ScopedTypeVariables #-}
-{-# LANGUAGE StrictData #-}
 {-# LANGUAGE StandaloneDeriving #-}
+{-# LANGUAGE StrictData #-}
 {-# LANGUAGE TypeFamilies #-}
 {-# LANGUAGE UndecidableInstances #-}
 
@@ -13,17 +14,21 @@
 import Control.Monad
 import Control.Monad.Catch
 import Control.Monad.IO.Class
+import Data.Coerce
+import Data.Foldable
 import Data.IntMap (IntMap)
 import qualified Data.IntMap as IntMap
-import Data.Foldable
 import Data.Kind
-import Data.Coerce
+import Data.Proxy
 import Data.Set (Set)
 import qualified Data.Set as Set
 import Data.Void
 import Test.QuickCheck hiding (Failure, Success)
+import Test.QuickCheck.Gen
 import Test.QuickCheck.Monadic
 
+import qualified ManagedThread2 as Scheduler
+
 ------------------------------------------------------------------------
 
 class ( Monad (CommandMonad state)
@@ -96,6 +101,13 @@
   type CommandMonad state = IO
 -- end snippet StateModel
 
+-- start snippet runCommandMonad
+  -- If another command monad is used we need to provide a way run it inside the
+  -- IO monad. This is only needed for parallel testing, because IO is the only
+  -- monad we can execute on different threads.
+  runCommandMonad :: proxy state -> CommandMonad state a -> Scheduler.Signal -> IO a
+-- end snippet runCommandMonad
+
 ------------------------------------------------------------------------
 
 -- start snippet Var
@@ -219,10 +231,19 @@
 -- Another option would be to introduce a new type class `ReturnsReferences` and
 -- ask the user to manually implement it.
 
+hoist :: Monad m => (forall x. m x -> IO x) -> PropertyM m a -> PropertyM IO a
+hoist nat (MkPropertyM f) = MkPropertyM $ \g ->
+  let
+    MkGen h = f (fmap (fmap (return . ioProperty)) g)
+  in
+    MkGen (\r n -> nat (h r n))
+
 -- start snippet runCommands
 runCommands :: forall state. StateModel state
-            => Commands state -> PropertyM (CommandMonad state) ()
-runCommands (Commands cmds0) = go initialState emptyEnv cmds0
+            => Commands state -> PropertyM IO ()
+runCommands (Commands cmds0) =
+  hoist (flip (runCommandMonad (Proxy :: Proxy state)) Scheduler.newSingleThreadedSignal) $
+    go initialState emptyEnv cmds0
   where
     go :: state -> Env state -> [Command state (Var (Reference state))]
        -> PropertyM (CommandMonad state) ()
```

### Changes to parallel module

``` diff
--- ../stateful-pbt-with-fakes/src/Parallel.hs  2024-06-26 12:29:51.889932357 +0200
+++ src/Parallel.hs 2024-07-11 06:59:32.502563455 +0200
@@ -11,7 +11,6 @@
 
 module Parallel where
 
-import Control.Concurrent.Async
 import Control.Concurrent.STM
 import Control.Exception (SomeException, displayException, try)
 import Control.Monad
@@ -26,9 +25,13 @@
 import Data.Set (Set)
 import qualified Data.Set as Set
 import Data.Tree
+import System.Random
 import Test.QuickCheck
+import Test.QuickCheck.Gen
 import Test.QuickCheck.Monadic
+import Test.QuickCheck.Random
 
+import qualified ManagedThread2 as Scheduler
 import Stateful
 
 ------------------------------------------------------------------------
@@ -46,13 +49,6 @@
   shrinkCommandParallel ss cmd = shrinkCommand (maximum ss) cmd
 -- end snippet ParallelModel
 
--- start snippet runCommandMonad
-  -- If another command monad is used we need to provide a way run it inside the
-  -- IO monad. This is only needed for parallel testing, because IO is the only
-  -- monad we can execute on different threads.
-  runCommandMonad :: proxy state -> CommandMonad state a -> IO a
--- end snippet runCommandMonad
-
 -- start snippet ParallelCommands
 newtype ParallelCommands state = ParallelCommands [Fork state]
 
@@ -274,36 +270,41 @@
 
 ------------------------------------------------------------------------
 
+getSeed :: PropertyM m QCGen
+getSeed = MkPropertyM (\f -> MkGen (\r n -> unGen (f r) r n))
+
 -- start snippet runParallelCommands
 runParallelCommands :: forall state. ParallelModel state
                     => ParallelCommands state -> PropertyM IO ()
 runParallelCommands cmds0@(ParallelCommands forks0) = do
+  gen <- getSeed
+  liftIO (putStrLn ("Seed: " ++ show gen))
   forM_ (parallelCommands cmds0) $ \cmd -> do
     let name = commandName cmd
     monitor (tabulate "Commands" [name] . classify True name)
   monitor (tabulate "Concurrency" (map (show . length . unFork) forks0))
   q   <- liftIO newTQueueIO
   c   <- liftIO newAtomicCounter
-  env <- liftIO (runForks q c emptyEnv forks0)
+  (env, _gen') <- liftIO (runForks q c emptyEnv gen forks0)
   hist <- History <$> liftIO (atomically (flushTQueue q))
   let ok = linearisable env (interleavings hist)
   unless ok (monitor (counterexample (show hist)))
   assert ok
   where
-    runForks :: TQueue (Event state) -> AtomicCounter -> Env state -> [Fork state]
-             -> IO (Env state)
-    runForks _q _c env [] = return env
-    runForks  q  c env (Fork cmds : forks) = do
-      envs <- liftIO $
-        mapConcurrently (runParallelReal q c env) (zip [Pid 0..] cmds)
+    runForks :: RandomGen g => TQueue (Event state) -> AtomicCounter -> Env state -> g
+             -> [Fork state] -> IO (Env state, g)
+    runForks _q _c env gen [] = return (env, gen)
+    runForks  q  c env gen (Fork cmds : forks) = do
+      (envs, gen') <- liftIO $
+        Scheduler.mapConcurrently (runParallelReal q c env) (zip [Pid 0..] cmds) gen
       let env' = combineEnvs (env : envs)
-      runForks q c env' forks
+      runForks q c env' gen' forks
 
     runParallelReal :: TQueue (Event state) -> AtomicCounter -> Env state
-                    -> (Pid, Command state (Var (Reference state))) -> IO (Env state)
-    runParallelReal q c env (pid, cmd) = do
+                    -> Scheduler.Signal -> (Pid, Command state (Var (Reference state))) -> IO (Env state)
+    runParallelReal q c env signal (pid, cmd) = do
       atomically (writeTQueue q (Invoke pid cmd))
-      eResp <- try (runCommandMonad (Proxy :: Proxy state) (runReal (fmap (lookupEnv env) cmd)))
+      eResp <- try (runCommandMonad (Proxy :: Proxy state) (runReal (fmap (lookupEnv env) cmd)) signal)
       case eResp of
         Left (err :: SomeException) ->
           error ("runParallelReal: " ++ displayException err)
```

## Conclusion and further work

- some seeds don't give the minimal counterexample, shrinking can be
  improved as already pointed out in my previous post

- enumarate all interleavings upto some depth, model checking style,
  perhaps using smallcheck? Compare to dejafu library

- while this approach works in all languages due to its white-box
  nature, what would it take to have a black-box approach that's
  deterministic?

  - intercept syscalls rr (and hermit?)
  - hypervisor (Antithesis)
  - language support for user schedulers

[^1]: If you haven't heard of
    [fakes](https://martinfowler.com/bliki/TestDouble.html) before,
    think of them as a more elaborate test double than a mock. A mock of
    a component expects to be called in some particular way (i.e.
    exposes only some limited subset of the components API), and
    typically throw an expeception when called in any other way. While a
    fake exposes the full API and can be called just like the real
    component, but unlike the real component it takes some shortcuts.
    For example a fake might lose all data when restarted (i.e. keeps
    all data in memory, while the real component persists the data to
    some stable storage).

[^2]: The reason for shrinking not working so well with non-determinism
    is because shrinking stops when the property passes. So if some
    input causes the property to fail and then we rerun the property on
    a smaller input it might be the case that the smaller input still
    contains the race condition, but because the interleaving of threads
    is non-deterministic we are unlucky and the race condition isn't
    triggered and the property passes, which stops the shrinking
    process.

[^3]: Jepsen's [Knossos
    checker](https://aphyr.com/posts/314-computational-techniques-in-knossos)
    also uses linearisability checking and has found many
    [bugs](https://jepsen.io/analyses), so we are in good company.

    Note that the most recent Jepsen analyses use the [Elle
    checker](https://github.com/jepsen-io/elle), rather than the Knossos
    checker. The Elle checker doesn't do linearisability checking, but
    rather looks for cycles in the dependencies of database
    transactions. Checking for cycles is less general than
    linearisability checking, but also more efficient. See the Elle
    [paper](https://github.com/jepsen-io/elle/raw/master/paper/elle.pdf)
    for details.
