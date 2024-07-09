{-# LANGUAGE GADTs #-}

module ManagedThread where

import Data.IORef
import Control.Monad
import System.Random

------------------------------------------------------------------------

data AtomicCounter = AtomicCounter (IORef Int)

newCounter :: IO AtomicCounter
newCounter = do
  ref <- newIORef 0
  return (AtomicCounter ref)

incr :: AtomicCounter -> Command ()
incr (AtomicCounter ref) = do
  i <- Load ref 
  Store ref (i + 1)

get :: AtomicCounter -> Command Int
get (AtomicCounter ref) = Load ref 

------------------------------------------------------------------------

data ManagedThreadId a = ManagedThreadId
  { _program :: Program a
  }

-- XXX: Turn into list of commands...
newtype Program a = Program (Command a)

data Command a where
  Return :: a -> Command a
  (:>>=) :: Command a -> (a -> Command b) -> Command b
  Load   :: IORef a -> Command a
  Store  :: IORef a -> a -> Command ()

instance Functor Command where
  fmap = liftM

instance Applicative Command where
  pure = Return
  (<*>) = ap

instance Monad Command where
  return = pure
  (>>=)  = (:>>=)

stepCommand :: Command a -> IO (Either (Command a) a)
stepCommand (Return x) = return (Right x)
stepCommand (m :>>= k) = case m of
  Return x -> return (Left (k x))
  m' :>>= k' -> do
    res <- stepCommand m'
    case res of
      Left c  -> return (Left ((c :>>= k') :>>= k))
      Right y -> return (Left ((k' y) :>>= k))
  Load ref -> do
    x <- readIORef ref
    return (Left (k x))
  Store ref x -> do
    writeIORef ref x
    return (Left (k ()))
stepCommand (Load ref)    = Right <$> readIORef ref
stepCommand (Store ref x) = Right <$> writeIORef ref x

spawn :: Program a -> ManagedThreadId a
spawn = ManagedThreadId

schedule :: ManagedThreadId a -> ManagedThreadId a -> StdGen -> IO ()
schedule (ManagedThreadId (Program cmd10)) (ManagedThreadId (Program cmd20)) = go (Just cmd10) (Just cmd20)
  where
    go :: Maybe (Command a) -> Maybe (Command a) -> StdGen -> IO ()
    go Nothing Nothing _gen = return ()
    go (Just cmd1) Nothing gen = do
      res <- stepCommand cmd1
      case res of
        Left cmd1' -> go (Just cmd1') Nothing gen
        Right _x   -> return ()
    go Nothing (Just cmd2) gen = do
      res <- stepCommand cmd2
      case res of
        Left cmd2' -> go Nothing (Just cmd2') gen
        Right _x   -> return ()
    go (Just cmd1) (Just cmd2) gen = do
      let (b, gen') = random gen
      if b 
      then do
        res <- stepCommand cmd1
        case res of
          Left cmd1' -> go (Just cmd1') (Just cmd2) gen'
          Right _x   -> go Nothing (Just cmd2) gen'
      else do
        res <- stepCommand cmd2
        case res of
          Left cmd2' -> go (Just cmd1) (Just cmd2') gen'
          Right _x   -> go (Just cmd1) Nothing gen'

test :: Int -> IO (Int, Bool)
test seed = do
  counter <- newCounter
  let tid1 = spawn (Program (incr counter))
      tid2 = spawn (Program (incr counter))
  let gen  = mkStdGen seed
  schedule tid1 tid2 gen
  Right two <- stepCommand (get counter)
  return (seed, two == 2)
