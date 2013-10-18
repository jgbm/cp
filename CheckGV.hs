{-# LANGUAGE PatternGuards #-}
module CheckGV where

import Control.Monad.Error
import Data.List
import Syntax.AbsGV
import Syntax.PrintGV

--------------------------------------------------------------------------------
-- Types, substitutions, and unifications

dual :: Session -> Session
dual (Dual st)    = st
dual (SVar v)     = Dual (SVar v)
dual (Output t s) = Input t (dual s)
dual (Input t s)  = Output t (dual s)
dual (Sum cs)     = Choice [Label l (dual s) | Label l s <- cs]
dual (Choice cs)  = Sum [Label l (dual s) | Label l s <- cs]
dual InTerm       = OutTerm
dual OutTerm      = InTerm

linear :: Type -> Bool
linear (LinFun _ _) = True
linear (Tensor _ _) = True
linear (Lift _)     = True
linear _            = False

unlimited :: Type -> Bool
unlimited = not . linear

--------------------------------------------------------------------------------
-- Typechecking monad and non-proper morphisms

type Environment = [Typing]

newtype Check t = C{ runCheck :: Environment -> Either String (t, Environment) }
instance Functor Check
    where fmap f (C g) = C (\e -> case g e of
                                    Left err -> Left err
                                    Right (v, e') -> Right (f v, e'))
instance Monad Check
    where return x = C (\e -> Right (x, e))
          C f >>= g = C (\e -> case f e of
                                 Left err -> Left err
                                 Right (v, e') -> runCheck (g v) e')
          fail s = C (\e -> Left s)

typeFrom :: Typing -> Type
typeFrom (Typing _ t) = t

nameFrom :: Typing -> LIdent
nameFrom (Typing id _) = id

checkLinear :: Check ()
checkLinear = C (\e -> case filter (linear . typeFrom) e of
                         [] -> Right ((), e)
                         e' -> Left ("    Failed to consume bindings for " ++ intercalate "," (map (printTree . nameFrom) e')))

-- Limits the environment to only those typings satisfying the given predicate;
-- excluded bindings and restored after the subcomputation is evaluated.
restrict :: (Typing -> Bool) -> Check t -> Check t
restrict p c = C (\e -> let (eIn, eOut) = partition p e
                        in  case runCheck c eIn of
                              Left err -> Left err
                              Right (v, eIn') -> Right (v, eIn' ++ eOut))

-- Find the type of a variable; if its type is linear, remove it from the
-- environment.
consume :: LIdent -> Check Type
consume x = C (\e -> case partition ((x ==) . nameFrom) e of
                       ([], _)            -> Left ("    Failed to find binding for " ++ printTree x)
                       ([Typing _ t], e')
                           | unlimited t  -> Right (t, e)
                           | otherwise    -> Right (t, e')
                       _                  -> error ("Multiple bindings for " ++ printTree x))

-- Add a new binding to the environment; if its type is linear, assure that it
-- is consumed in the provided subcomputation.  If this shadows an existing
-- binding, the existing binding is restored after the subcomputation finishes.
provide :: LIdent -> Type -> Check t -> Check t
provide x t c = C (\e -> let (included, excluded) = partition ((x /=) . nameFrom) e
                         in  case runCheck c (Typing x t : included) of
                               Left err -> Left err
                               Right (y, e')
                                   | unlimited t -> Right (y, excluded ++ filter ((x /=) . nameFrom) e')
                                   | otherwise   -> case partition ((x ==) . nameFrom) e' of
                                                      ([], _) -> Right (y, excluded ++ e')
                                                      _       -> Left ("    Failed to consume binding for " ++ printTree x))

mapPar :: (t -> Check u) -> [t] -> Check [u]
mapPar f xs =
    C (\e -> case runCheck (unzip `fmap` mapM (withEnvironment e . f) xs) e of
               Left err -> Left err
               Right ((ys, es), e')
                   | all (same (filterUnlimited e')) (map filterUnlimited es) ->  Right (ys, e')
                   | otherwise -> Left ("    Branches make inconsistent demands on linear environment"))
    where withEnvironment e c = C (\_ -> case runCheck c e of
                                           Left err -> Left err
                                           Right (y, e) -> Right ((y, e), e))
          filterUnlimited e = [Typing v t | Typing v t <- e, linear t]
          domain = map nameFrom
          equalAsSet xs ys = all (`elem` xs) ys && all (`elem` ys) xs
          getBinding x b = case partition ((x ==) . nameFrom) b of
                             ([Typing _ t], _) -> t
                             _                 -> error "getBinding"
          same b b' = equalAsSet (domain b) (domain b') && and [getBinding x b == getBinding x b' | x <- domain b]

addErrorContext :: String -> Check t -> Check t
addErrorContext s c = C (\e -> case runCheck c e of
                                 Left err -> Left (s ++ '\n' : err)
                                 Right r  -> Right r)

--------------------------------------------------------------------------------
-- With all that out of the way, type checking itself can be implemented
-- directly.

check :: Term -> Check Type
check te = addErrorContext ("Checking \"" ++ printTree te ++ "\"") (check' te)
    where check' (Var x)   = consume x
          check' Unit      = return UnitType
          check' (UnlLam x t m) =
              do u <- restrict (unlimited . typeFrom) (provide x t (check m))
                 return (UnlFun t t)
          check' (LinLam x t m) =
              do u <- provide x t (check m)
                 return (LinFun t t)
          check' (App m n) =
              do mty <- check m
                 nty <- check n
                 case mty of
                   v `LinFun` w
                       | v == nty -> return w
                       | otherwise -> fail ("   Argument has type " ++ printTree nty ++ " but expected " ++ printTree v)
                   v `UnlFun` w
                       | v == nty -> return w
                       | otherwise -> fail ("   Argument has type " ++ printTree nty ++ " but expected " ++ printTree v)
                   _ -> fail ("   Application of non-function of type " ++ printTree mty)
          check' (Pair m n) =
              liftM2 Tensor (check m) (check n)
          check' (Let (BindName x) m n) =
              do t <- check m
                 provide x t (check n)
          check' (Let (BindPair x y) m n) =
              do mty <- check m
                 case mty of
                   Tensor xty yty -> provide x xty (provide y yty (check n))
                   _              -> fail ("    Attempted to pattern-match non-pair of type " ++ printTree mty)
          check' (Send m n) =
              do mty <- check m
                 nty <- check n
                 case nty of
                   Lift (Output v w)
                        | mty == v -> return (Lift w)
                        | otherwise -> fail ("    Sent value has type " ++ printTree mty ++ " but expected " ++ printTree v)
                   _ -> fail ("    Channel of send operation has unexpected type " ++ printTree nty)
          check' (Receive m) =
              do mty <- check m
                 case mty of
                   Lift (Input v w) -> return (v `Tensor` Lift w)
                   _ -> fail ("    Channel of receive operation has unexpected type " ++ printTree mty)
          check' (Select l m) =
              do mty <- check m
                 case mty of
                   Lift (Sum cs) -> Lift `fmap` lookupLabel l cs
                   _             -> fail ("    Channel of select operation has unexepcted type " ++ printTree mty)
              where
          check' (Case m bs)
              | Just l <- duplicated bs = fail ("    Duplicated case label " ++ printTree l)
              | otherwise = do mty <- check m
                               case mty of
                                 Lift (Choice cs) -> do (t:ts) <- mapPar (checkBranch cs) bs
                                                        if all (t ==) ts
                                                        then return t
                                                        else fail ("   Divergent results of case branches:" ++ intercalate ", " (map printTree (nub (t:ts))))
                                 _                -> fail ("    Channel of case operation has unexpected type " ++ printTree mty)
              where duplicated [] = Nothing
                    duplicated (Branch l _ _ : bs)
                        | or [l == l' | Branch l' _ _ <- bs] = Just l
                        | otherwise = duplicated bs
                    checkBranch cs (Branch l x n) =
                        do s <- lookupLabel l cs
                           provide x (Lift s) (check n)
          check' (With l st m n) =
              do mty <- provide l (Lift st) (check m)
                 case mty of
                   Lift OutTerm -> provide l (Lift (dual st)) (check n)
                   _            -> fail ("    Unexpected type of left channel " ++ printTree mty)
          check' (End m) =
              do mty <- check m
                 case mty of
                   ty `Tensor` Lift InTerm -> return ty
                   _                       -> fail ("    Unexpected type of right channel " ++ printTree mty)


lookupLabel :: LIdent -> [LabeledSession] -> Check Session
lookupLabel l [] = fail ("    Unable to find label " ++ printTree l)
lookupLabel l (Label l' s : rest)
    |  l == l'   = return s
    | otherwise  = lookupLabel l rest

checkAgainst :: Term -> Type -> Check ()
checkAgainst te ty = do ty' <- check te
                        if ty == ty'
                        then return ()
                        else fail ("Expected type " ++ printTree ty ++ " but actual type is " ++ printTree ty')