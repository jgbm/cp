module RunGV where

import Syntax.AbsGV
import Syntax.PrintGV

import Control.Monad
import Control.Monad.Error
import Data.Maybe

data Value =
   VUnit
 | VFun Var Term
 | VPair Value Value
 | VLabel Label
 | VChannel Chan
   deriving (Eq,Ord,Show)

-- runtime channels
type Port = Int
type Chan = (Port, Port)

type Var = LIdent
type Label = LIdent

type Buffer = (Port, [Value])
type Env k v = [(k, v)]
type VEnv = Env Var Value
type PEnv = Env Port Port

-- (port forwarding, buffers, threads, next port name)
type Configuration = (PEnv, [Buffer], [Thread], Port)

-- a possibly suspended value
--
-- We always instantiate the type parameter to the type Value. The
-- type parameter is only there to allow us to declare Susp to be a
-- monad and hence use do notation!
data Susp a =
   Return a
 | SExit Value
 | SWith (Chan -> (Thread, Thread))         (Value -> Susp a)
 | SLink Chan Chan                          (Value -> Susp a)
 | SSend Value Chan                         (Value -> Susp a)
 | SReceive Chan                            (Value -> Susp a)
 | SSelect Label Chan                       (Value -> Susp a)
 | SCase Chan (Env Label (Value -> Thread)) (Value -> Susp a)
 | SServe Chan (Chan -> Thread)             (Value -> Susp a)
 | SRequest Chan                            (Value -> Susp a)
 | SServeMore Chan (Chan -> Thread)

type Thread = Susp Value

instance Monad Susp where
  return = Return
  Return v       >>= k = k v
  SExit v        >>= k = SExit v
  SWith f k'     >>= k = SWith f     (k' >=> k)
  SLink c1 c2 k' >>= k = SLink c1 c2 (k' >=> k)
  SSend v c k'   >>= k = SSend v c   (k' >=> k)
  SReceive c k'  >>= k = SReceive c  (k' >=> k)
  SSelect l c k' >>= k = SSelect l c (k' >=> k)
  SCase c bs k'  >>= k = SCase c bs  (k' >=> k)
  SServe c f k'  >>= k = SServe c f  (k' >=> k)
  SRequest c k'  >>= k = SRequest c  (k' >=> k)
  SServeMore c f >>= k = SServeMore c f


sexit       = SExit
swith f     = SWith f return
slink c1 c2 = SLink c1 c2 return
ssend v c   = SSend v c return
sreceive c  = SReceive c return
sselect l c = SSelect l c return
scase v bs  = SCase v bs return
sserve c f  = SServe c f return
srequest c  = SRequest c return

emptyEnv :: Env k a
emptyEnv = []

extend :: Env k a -> (k, a) -> Env k a
extend = flip (:)


-- run as much pure computation as possible in a single thread
runPure :: VEnv -> Term -> Thread
runPure env e = runPure' env e where
  rp = runPure env
  runPure' env (Var x) =
    case lookup x env of
      Nothing -> error ("Unbound variable: " ++ show x)
      Just v -> return v
  runPure' env Unit = return VUnit
  runPure' env (Link e1 e2) =
    do (VChannel c1) <- rp e1
       (VChannel c2) <- rp e2
       slink c1 c2
  runPure' env (LinLam x _ e) = return (VFun x e)
  runPure' env (UnlLam x _ e) = return (VFun x e)
  runPure' env (App f a) =
    do VFun x e <- rp f
       v <- rp a
       runPure (extend env (x, v)) e
  runPure' env (Pair e1 e2) =
    do v1 <- rp e1
       v2 <- rp e2
       return (VPair v1 v2)
  runPure' env (Let (BindName x) e e') =
    do v <- rp e
       runPure (extend env (x, v)) e'
  runPure' env (Let BindUnit e e') =
    do VUnit <- rp e
       runPure env e'
  runPure' env (Let (BindPair x1 x2) e e') =
    do (VPair v1 v2) <- rp e
       runPure (extend (extend env (x1, v1)) (x2, v2)) e'
  runPure' env (With x _ e1 e2) =
    swith (\(p1, p2) -> (runPure (extend env (x, VChannel (p1, p2))) e1,
                         runPure (extend env (x, VChannel (p2, p1))) e2))
  runPure' env (End e) =
    do (VChannel _) <- rp e
       return VUnit
  runPure' env (Send m n) =
    do v <- rp m
       (VChannel c) <- rp n
       ssend v c
  runPure' env (Receive e) =
    do (VChannel c) <- rp e
       sreceive c
  runPure' env (Select l e) =
    do (VChannel c) <- rp e
       sselect l c
  runPure' env (Case e bs) =
    do (VChannel c) <- rp e
       let bs' = map (\(Branch l x e) -> (l, \v -> runPure (extend env (x, v)) e)) bs
       scase c bs'
  runPure' env (Serve s x e) =
    do VChannel s' <- rp (Var s)
       sserve s' (\(p1, p2) -> runPure (extend env (x, VChannel (p2, p1))) e)
  runPure' env (Request s) =
    do VChannel s' <- rp (Var s)
       srequest s'

blocked = Left Nothing
exit v = Left (Just v)

emptyBuffer :: Port -> Buffer
emptyBuffer p = (p, [])

-- run the next command in the current thread
runCommand :: Thread -> Configuration -> Either (Maybe Value) Configuration
runCommand (Return _) _ = blocked -- this is actually a finished thread rather than a blocked thread
runCommand (SExit v)  _ = exit v
runCommand (SWith f k) (penv, bufs, ts, next) =
  return (penv, (emptyBuffer (next+1)):(emptyBuffer next):bufs, ts ++ [t1, t2 >>= k], next+2)
  where
    (t1, t2) = f (next, next+1)
runCommand (SLink c1 c2 k) (penv, bufs, ts, next) =
  return (linkChannels c1 c2 penv, bufs, ts ++ [k (VChannel c2)], next)
runCommand (SSend v c@(p, _) k) conf@(penv, bufs, ts, next) =
  return (penv, sendValue v penv bufs p, ts ++ [k (VChannel c)], next)
runCommand (SReceive c@(_, p) k) (penv, bufs, ts, next) =
  do (v, bufs') <- receiveValue penv bufs p 
     return (penv, bufs', ts ++ [k (VPair v (VChannel c))], next)
runCommand (SSelect l c@(p, _) k) (penv, bufs, ts, next) =
  return (penv, sendLabel l penv bufs p, ts ++ [k (VChannel c)], next)
runCommand (SCase c@(_, p) bs k) (penv, bufs, ts, next) =
  do (s, bufs') <- receiveLabel c bs penv bufs p
     return (penv, bufs', ts ++ [s >>= k], next)
runCommand (SServe s f k) (penv, bufs, ts, next) =
  -- the continuation expects a channel of type end!, so it can never
  -- use its argument, so the current channel will do as a value to
  -- send (undefined should work just as well)
  return (penv, bufs, ts ++ [k (VChannel s), SServeMore s f], next)
runCommand (SServeMore s@(_, p) f) (penv, bufs, ts, next) =
  do (VChannel c, bufs') <- receiveValue penv bufs p
     return (penv, bufs', ts ++ [f c, SServeMore s f], next)
runCommand (SRequest (p, _) k) (penv, bufs, ts, next) =
  return (penv, bufs', ts ++ [k v], next+2)
  where
    v = VChannel (next, next+1)
    bufs' = sendValue v penv ((emptyBuffer (next+1)):(emptyBuffer next):bufs) p

--  p1 <==> q1
--  |       |
--  |       |
-- \|/     \|/
--  p2 <==> q2
linkChannels :: Chan -> Chan -> PEnv -> PEnv
linkChannels (p1, q1) (p2, q2) penv = extend (extend penv (q1, q2)) (p1, p2)

sendValue :: Value -> PEnv -> [Buffer] -> Port -> [Buffer]
sendValue v penv bufs p =
  case lookup p penv of
    Nothing ->
      map (\(q, vs) -> if p == q then (q, vs ++ [v])
                       else (q, vs)) bufs
    Just q ->
      -- follow the link to the next buffer
      sendValue v penv bufs q

sendLabel :: Label -> PEnv -> [Buffer] -> Port -> [Buffer]
sendLabel l = sendValue (VLabel l) 

receiveValue :: PEnv ->  [Buffer] -> Port -> Either (Maybe Value) (Value, [Buffer])
receiveValue penv bufs p =
  case focus p bufs of
    (_, [], _) ->
      case lookup p penv of
        Nothing -> blocked
        Just q  ->
          -- if this port's buffer is exhausted then follow the link
          -- to the next one
          receiveValue penv bufs q
    (xs, v:vs, ys) ->
      return (v, defocus p (xs, vs, ys))
  where
    focus p bufs = focus' p [] bufs where
      focus' p lbufs ((q, vs):rbufs) | p == q = (lbufs, vs, rbufs)
      focus' p lbufs (buf:rbufs)              = focus' p (buf:lbufs) rbufs
    defocus p (lbufs, vs, rbufs) = reverse lbufs ++ extend rbufs (p, vs)

receiveLabel :: Chan -> Env Label (Value -> Thread) -> PEnv ->  [Buffer] -> Port -> Either (Maybe Value) (Thread, [Buffer])
receiveLabel c bs penv bufs p =
  do (VLabel l, bufs) <- receiveValue penv bufs p
     v <- matchLabel c l bs
     return (v, bufs)
  where
    matchLabel c l bs =
      case lookup l bs of
        Nothing -> blocked  -- really this is a type error so should never occur
        Just f  -> return $ f (VChannel c)

-- run the current configuration until either
--   * deadlock occurs (guaranteed never to happen by the GV type system)
--   * the top-level exits with a final value 
runConfig :: Configuration -> Configuration
runConfig conf = runConfig' 0 conf where
  -- keep going until all threads are blocked
  runConfig' :: Int -> Configuration -> Configuration
  runConfig' n conf@(penv, bufs, ts, next) | n >= length ts = conf
  runConfig' n conf@(penv, bufs, t:ts, next) =
    case runCommand t (penv, bufs, ts, next) of
      Left Nothing  -> runConfig' (n+1) (penv, bufs, ts ++ [t], next)
      Left (Just v) -> conf
      Right conf    -> runConfig conf

runProgram :: Term -> Value
runProgram e =
  let conf@(penv, bufs, t:ts, next) = runConfig (emptyEnv, [], [runPure [] e >>= sexit], 0) in
  case t of
    SExit v -> v
    _       -> error ("Deadlock! " ++ show (penv, bufs, map threadHead (t:ts), next))

-- debugging stuff

-- this gives us the head of a thread which we can easily show for
-- debugging
data ThreadHead =
   THReturn Value
 | THExit Value
 | THWith 
 | THLink Chan Chan
 | THSend Value Chan
 | THReceive Chan
 | THSelect Label Chan
 | THCase Chan
 | THServe Chan
 | THRequest Chan
 | THServeMore Chan
 deriving Show

threadHead :: Thread -> ThreadHead
threadHead (Return v)       = THReturn v
threadHead (SExit v)        = THExit v
threadHead (SWith _ _)      = THWith
threadHead (SLink c d _)    = THLink c d
threadHead (SSend v c _)    = THSend v c
threadHead (SReceive c _)   = THReceive c
threadHead (SSelect l c _)  = THSelect l c
threadHead (SCase c _ _)    = THCase c
threadHead (SServe c _ _)   = THServe c
threadHead (SRequest c _)   = THRequest c
threadHead (SServeMore c _) = THServeMore c


