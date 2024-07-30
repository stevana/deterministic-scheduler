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

The implementation of the deterministic scheduler can be split up in
three parts. First we'll implement a way for the spawned threads to
communicate with the scheduler, this communication channel will be used
to pause and unpause the threads. After that we'll make a wrapper
datatype around Haskell's threads which also includes the communication
channel. Finally, we'll have all the pieces to implement the
deterministic scheduler itself.

### Thread-scheduler communication

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

We'll call our communcation channel `Signal`:

``` haskell
data Signal = SingleThreaded | MultiThreaded (TMVar ())
  deriving Eq
```

There are two ways to create a `Signal`, one for single-threaded and
another for multi-threaded execution:

``` haskell
newSingleThreadedSignal :: Signal
newSingleThreadedSignal = SingleThreaded

newMultiThreadedSignal :: IO Signal
newMultiThreadedSignal = MultiThreaded <$> newEmptyTMVarIO
```

The idea being that in the single-threaded case the scheduler shouldn't
be doing anything. In particular pausing a thread in the single-threaded
case is a no-op:

``` haskell
pause :: Signal -> IO ()
pause SingleThreaded        = return ()
pause (MultiThreaded tmvar) = atomically (takeTMVar tmvar)
```

Notice that in the multi-threaded case the pause operation will try to
take a value from the `TMVar` and also notice that the `TMVar` starts
off being empty, so this will cause the thread to block.

The way the scheduler can unpause the thread is by putting a unit value
into the `TMVar`, which will cause the `takeTMVar` finish.

``` haskell
unpause :: Signal -> IO ()
unpause SingleThreaded        = error
  "unpause: a single thread should never be paused"
unpause (MultiThreaded tmvar) = atomically (putTMVar tmvar ())
```

For our scheduler implementation we'll also need a way to check if a
thread is paused:

``` haskell
isPaused :: Signal -> STM Bool
isPaused SingleThreaded        = return False
isPaused (MultiThreaded tmvar) = isEmptyTMVar tmvar
```

It's also useful to be able to check if all threads are paused:

``` haskell
waitUntilAllPaused :: [Signal] -> IO ()
waitUntilAllPaused signals = atomically $ do
  bs <- mapM isPaused signals
  guard (and bs)
```

Notice that STM makes this easy as we can do this check atomically.

### Managed threads

Having implemented the communication channel between the thread and the
scheduler, we are now ready to introduce our "managed" threads (we call
them "managed" because they are managed by the scheduler). These threads
are basically a wrapper around Haskell's `Async` threads that also
includes our communication channel, `Signal`.

``` haskell
data ManagedThreadId a = ManagedThreadId
  { _mtidName   :: String
  , _mtidSignal :: Signal
  , _mtidAsync  :: Async a
  }
  deriving Eq
```

Our managed thread can be spawned as follows:

``` haskell
spawn :: String -> (Signal -> IO a) -> IO (ManagedThreadId a)
spawn name io = do
  s <- newMultiThreadedSignal
  a <- async (io s)
  return (ManagedThreadId name s a)
```

Noticed that the spawned IO action gets access to the communication
channel.

The `Async` thread API exposes a way to check if a thread is still
executing, threw an exeception or finished yeilding a result. We'll
extend this by also being able to check if the thread is paused as
follows.

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

### Scheduler

We now got all the pieces we need to implement our deterministic
scheduler.

The idea is to wait until all threads are paused, then step one of them
and wait until it either pauses again or finishes. If it pauses again,
then repeat the stepping. If it finishes, remove it from the list of
stepped threads and continue stepping.

``` haskell
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

We can now also implement a useful higher-level combinator:

``` haskell
mapConcurrently :: RandomGen g => (Signal -> a -> IO b) -> [a] -> g -> IO ([b], g)
mapConcurrently f xs gen = do
  mtids <- forM (zip [0..] xs) $ \(i, x) ->
    spawn ("Thread " ++ show i) (\sig -> f sig x)
  schedule mtids gen
```

### Example: broken atomic counter

To show that our scheduler is indeed deterministic, let's implement the
race condition between two increments from the introduction.

First let's introduce an interface for shared memory.

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

The idea is that we will use two different instances of this interface:
a "real" one which just does what we'd expect from shared memory, and a
"fake" one which pauses around the real operations. The real one will be
used when we deploy the actual software and the fake one while we do our
testing.

We can now implement our counter example against the shared memory
interface:

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

Finally, we can implement the race condition test using the counter and
two threads that do increments:

``` haskell
test :: Int -> IO (Int, Bool, Int)
test seed = do
  counter <- newCounter
  mtid1 <- spawn "0" (\signal -> incr (fakeMem signal) counter)
  mtid2 <- spawn "1" (\signal -> incr (fakeMem signal) counter)
  let gen  = mkStdGen seed
  _ <- schedule [mtid1, mtid2] gen
  two <- get realMem counter
  return (seed, two == 2, two)

test1 :: IO ()
test1 = mapM_ (\seed -> print =<< test seed) [0..10]
```

The test is parametrised by a seed for the scheduler. If we run it with
different seeds we get different outcomes:

    >>> test1
    (0,True,2)
    (1,True,2)
    (2,False,1)
    (3,True,2)
    (4,False,1)
    (5,True,2)
    (6,False,1)
    (7,False,1)
    (8,True,2)
    (9,True,2)
    (10,False,1)

If we fix the seed to one which makes our test fail:

``` haskell
test2 :: IO ()
test2 = let seed = 2 in replicateM_ 10 (print =<< test seed)
```

then we get the same outcome everytime:

    >>> test2
    (2,False,1)
    (2,False,1)
    (2,False,1)
    (2,False,1)
    (2,False,1)
    (2,False,1)
    (2,False,1)
    (2,False,1)
    (2,False,1)
    (2,False,1)

These quick tests seem to suggest that our scheduler is in fact
deterministic.

## Parallel property-based testing recap

In our counter example above, we had two concurrent increments, in this
case it's easy to see what the answer must be (the counter must have the
value of two, if we start counting from zero and increment by one).

However for more complicated scenarios it gets less clear, consider:

- two concurrent incrs + get
- timeouts / crashing threads
- more complicated datastructures than a counter, e.g. key-value store
  with deletes

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

- eventual consistency?

## Integrating the scheduler into the testing

I don't want to reimplement the parallel property-based testing
machinary from my previous post here, but merely show that integrating
the deterministic scheduler isn't too much work.

We need to change the code from the previous post in three different
places: the sequential module, the parallel module and the counter
example itself.

### Changes to sequential module

First we import the library code that we wrote above in this post:

``` diff
+import qualified ManagedThread2 as Scheduler
```

Then we move the `runCommandMonad` method from the `ParallelModel` class
into the `StateModel` class and change it so that it has access to the
communication channel to the scheduler (`Signal`):

``` diff
+  runCommandMonad :: proxy state -> CommandMonad state a -> Scheduler.Signal -> IO a
```

We then change the `runCommands` function to use `runCommandMonad` and
use a single-threaded `Signal`, i.e. one that doesn't do any pauses:

``` diff
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

In order for this to typecheck we need a helper function that changes
the underlying monad of a `PropertyM` (QuickCheck's monadic properties):

``` diff
+hoist :: Monad m => (forall x. m x -> IO x) -> PropertyM m a -> PropertyM IO a
+hoist nat (MkPropertyM f) = MkPropertyM $ \g ->
+  let
+    MkGen h = f (fmap (fmap (return . ioProperty)) g)
+  in
+    MkGen (\r n -> nat (h r n))
```

### Changes to parallel module

Again we import the deterministic scheduler that we defined in this
post:

``` diff
+import qualified ManagedThread2 as Scheduler
```

As we said above, the `runCommandMonad` method was moved into the
sequential testing module:

``` diff
-  runCommandMonad :: proxy state -> CommandMonad state a -> IO a
```

We'll reuse QuickCheck's seed for our scheduler, the following helper
function extracts the seed from QuickCheck's `PropertyM`:

``` diff
+getSeed :: PropertyM m QCGen
+getSeed = MkPropertyM (\f -> MkGen (\r n -> unGen (f r) r n))
```

We now have all the pieces we need to rewrite `runParallelCommands` to
use the deterministic scheduler:

``` diff
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
+  env <- liftIO (runForks q c emptyEnv gen forks0)
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
+             -> [Fork state] -> IO (Env state)
+    runForks _q _c env _gen [] = return env
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

### Changes to the counter example

``` diff
+import qualified ManagedThread2 as Scheduler
```

``` diff
-incrRaceCondition :: IO ()
-incrRaceCondition = do
-  n <- readIORef gLOBAL_COUNTER
-  threadDelay 100
-  writeIORef gLOBAL_COUNTER (n + 1)
-  threadDelay 100
+incrRaceCondition :: Scheduler.SharedMemory Int -> IO ()
+incrRaceCondition mem = do
+  n <- liftIO (Scheduler.memReadIORef mem gLOBAL_COUNTER)
+  Scheduler.memWriteIORef mem gLOBAL_COUNTER (n + 1)
 
-get :: IO Int
-get = readIORef gLOBAL_COUNTER
+get :: Scheduler.SharedMemory Int -> IO Int
+get mem = Scheduler.memReadIORef mem gLOBAL_COUNTER
```

``` diff
+  type CommandMonad Counter = ReaderT Scheduler.Signal IO
+
   -- We also need to explain which part of the counter API each command
   -- corresponds to.
-  runReal :: Command Counter r -> IO (Response Counter r)
-  runReal Get  = Get_  <$> get
-  runReal Incr = Incr_ <$> incrRaceCondition
+  runReal :: Command Counter r -> ReaderT Scheduler.Signal IO (Response Counter r)
+  runReal cmd = do
+    sig <- ask
+    let mem = Scheduler.fakeMem sig
+    case cmd of
+      Get  -> liftIO (Get_  <$> get mem)
+      Incr -> liftIO (Incr_ <$> incrRaceCondition mem)
```

``` diff
+  runCommandMonad _ m sig = runReaderT m sig
+
 prop_counter :: Commands Counter -> Property
 prop_counter cmds = monadicIO $ do
-  run reset
+  liftIO reset
   runCommands cmds
   assert True
```

``` diff
-instance ParallelModel Counter where
-
-  -- The command monad is IO, so we don't need to do anything here.
-  runCommandMonad _ = id
+instance ParallelModel Counter
 
 prop_parallelCounter :: ParallelCommands Counter -> Property
 prop_parallelCounter cmds = monadicIO $ do
-  replicateM_ 10 $ do
-    run reset
-    runParallelCommands cmds
+  run reset
+  runParallelCommands cmds
   assert True
```

## Conclusion and further work

- some seeds don't give the minimal counterexample, shrinking can be
  improved as already pointed out in my previous post

- enumarate all interleavings upto some depth, model checking style,
  perhaps using smallcheck? Compare to dejafu library

- rewrite into proper library?

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
