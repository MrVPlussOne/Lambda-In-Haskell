{-#LANGUAGE TypeSynonymInstances, FlexibleInstances #-}

module LambdaTerm
    (
      VarName, Term, TermShape(..), VarString(..),
      isPrim, prettyShow, prettyPrint,
      (#), lambda, λ, lambdas, λs, lgh, occursIn, freeVars, boundVars,
      renameVar, substitute, (/:), patternMatch,
      alphaEqual, subTerms,
      _x,_y,_z,_u,_v,_w
    ) where

import MyOps
import Test.QuickCheck hiding (subterms)
import qualified Data.Set as S

-- $setup
-- >>> import Test.QuickCheck
-- >>> import Data.List(sort)
-- >>> import Parse

type VarName = String

type Term = TermShape VarName

data TermShape a = Var a
                | Apply (TermShape a) (TermShape a)
                | Abstr {variable::a, scope::TermShape a}
                  deriving (Eq, Ord)

instance Show Term where show = prettyShow

instance Arbitrary Term where
  arbitrary = do
    r <- choose (1,4) :: Gen Int
    if r == 1
      then oneof [Apply <$> arbitrary <*> arbitrary
                 ,Abstr <$> (getVarString <$> arbitrary) <*> arbitrary]
      else Var . getVarString <$> arbitrary

newtype VarString = VarString {getVarString :: VarName}
  deriving (Eq, Show)

instance Arbitrary VarString where
  arbitrary = do
    i <- choose (1,6)
    return $ VarString (nameList !! i)

-- | an infinite list of all available variable names
-- >>> take 3 nameList
-- ["u","v","w"]
nameList :: [VarName]
nameList = iterate addPrime basicList |> concat
  where basicList = ["u","v","w","x","y","z"] ++ map (:[]) ['a'..'t']
        addPrime = map (++ "'")

{- |
Returns whether this Term is a primitive (∈ atoms)
>>> isPrim _x
True
>>> isPrim _y
True

prop> isPrim (Var x) == True
prop> isPrim (Apply x y) == False
prop> isPrim (Abstr x y) == False
-}
isPrim :: Term -> Bool
isPrim (Var _) = True
isPrim _ = False

prettyShow :: Term -> String
prettyShow t =
  case t of
    Var v -> v
    Apply x y -> surroundAbstr x ++ " " ++ surroundNonPrim y
    Abstr v term -> "λ" ++ v ++ showBody
      where showBody = case term of
                              Abstr _ _ -> ' ': tail (prettyShow term)
                              _ -> ". " ++ prettyShow term
  where surroundNonPrim x =
          if isPrim x then prettyShow x else "(" ++ prettyShow x ++ ")"
        surroundAbstr l@(Abstr _ _) = "(" ++ prettyShow l ++ ")"
        surroundAbstr other = prettyShow other

prettyPrint :: Term -> IO ()
prettyPrint = putStrLn . prettyShow

infixl 8 #
(#) :: TermShape a -> TermShape a -> TermShape a
(#) = Apply

-- | make an 'Abstr' term
lambda :: VarName -> Term -> Term
lambda = Abstr

-- | same as 'lambda'
λ :: VarName -> Term -> Term
λ = lambda

lambdas :: [VarName] -> Term -> Term
lambdas vars t = foldr lambda t vars

λs :: [VarName] -> Term -> Term
λs = lambdas

-- | the length of a term
-- prop> lgh x + lgh y == lgh (x#y)
-- prop> lgh x + 1 == lgh (lambda v x)
-- prop> isPrim x ==> lgh x == 1
lgh :: Integral a => Term -> a
lgh (Apply m n) = lgh m + lgh n
lgh (Abstr _ m) = 1 + lgh m
lgh a | isPrim a = 1
      | otherwise = error "Unknown term"

{- | λ-term contain relation
prop> p `occursIn` p
prop> p `occursIn` (p#m)
prop> p `occursIn` (m#p)
prop> p `occursIn` (lambda x p)
prop> Var x `occursIn` (lambda x m)
>>> (_x # _y) `occursIn` ((_x # _y) # lambda "x" (_x # _y))
True
-}
occursIn :: Term -> Term -> Bool
occursIn p = patternMatch f /> not . null
  where f x = if x == p then Just () else Nothing

type Set = S.Set

{- | Return a list of all free variable names in the given term
 >>> let fv = _x # _v # lambdas ["y","z"] (_y # _v) # _w |> freeVars
 >>> fv == S.fromList ["x", "v", "w"]
 True
 >>> let p = (λ "y" $ _y # _x # (λ "x" $ _y # (λ "y" _z) # _x)) # _v # _w
 >>> freeVars p == S.fromList ["x", "z", "v", "w"]
 True
-}
freeVars :: Term -> Set VarName
freeVars = withBinds S.empty
  where
    withBinds binds term =
      case term of
        Var v -> if v `elem` binds then S.empty else S.singleton v
        Apply m n -> withBinds binds m `S.union` withBinds binds n
        Abstr x e -> withBinds (S.insert x binds) e

{- | Return a list of all bounded variable names in the given term, please note
that there may be some 'freeVars' have the same name with those bounded.
prop> \(VarString x) -> x `S.member` boundVars (lambda x p)
-}
boundVars :: Term -> Set VarName
boundVars (Abstr v expr) = S.singleton v `S.union` boundVars expr
boundVars (Apply m n) = boundVars m `S.union` boundVars n
boundVars _ = S.empty

{- | Rename a variable if it's in the set, using the 'nameList'
prop> \(VarString v) -> renameVar (v, S.empty) == (v, S.empty)
prop> \(VarString v) -> v /= uu ==> let uu = head nameList in renameVar (v, S.singleton v) == (uu, S.fromList [v,uu])
 -}
renameVar ::  (VarName, Set VarName) -> (VarName, Set VarName)
renameVar unchanged@(old, used)
  | S.member old used = (newName, S.insert newName used)
  | otherwise = unchanged
  where newName = nameList |> filter (not . (`S.member` used)) |> head


-- | Substitute a variable by a term
-- prop> let Abstr z w = ("x",_w) /: (lambda "w" _x) in z /= "x" && w == _w
-- prop> ("x", p) /: (lambda "x" q) == (lambda "x" q)
-- prop> not ("v" `S.member` freeVars m) && null (boundVars m `S.intersection` freeVars (_v#p#q)) ==> (("v", p) /: ("x", _v) /: m) == ("x", p) /: m
substitute :: (VarName, Term) -> Term -> Term
substitute (x, n) (Var y) | x==y = n
substitute _ a | isPrim a = a
substitute s (Apply p q) = Apply (substitute s p) (substitute s q)
substitute s@(x, n) l@(Abstr y p)
    | x == y || not (x `S.member` freeVars p) = l
    | not (y `S.member` nFrees) = lambda y (substitute s p)
    | otherwise = lambda z (substitute s $ substitute (y, Var z) p)
    where nFrees = freeVars n
          (z, _) = renameVar (y, nFrees)
substitute _ _ = error "unkonwn pattern"

-- | operator of 'substitute'
infixr 9 /:
(/:) :: (VarName, Term) -> Term -> Term
(/:) = substitute

{- | Try to apply the function to all sub-patterns of the term, until the first Just-result encountered. Return Nothing if all sub-patterns make the function return Nothing.
>>> :{
let f a@(Apply _ _) = Just a
    f _ = Nothing
in patternMatch f (lambda "x" (_u # _v)) == Just (_u # _v)
:}
True

>>> :{
let f (a@(Abstr x (Var y))) | x==y = Just a
    f _ = Nothing
in patternMatch f (Apply (lambda "x" (Var "y")) (lambda "u" $ Var "u")) == Just (lambda "u" $ Var "u")
:}
True
-}
patternMatch :: (Term -> Maybe a) -> Term -> Maybe a
patternMatch f u =
  case u of
    (Apply a b) -> f u `mplus` rec a `mplus` rec b
    (Abstr v e) -> f u `mplus` rec (Var v) `mplus` rec e
    t -> f t
  where rec = patternMatch f

{- | Return wehter two term is alpha-equivalent
prop> parseExpr "λx. x(λx. x)" `alphaEqual` parseExpr "λy. y(λx. x)"
prop> parseExpr "λy. y(λx. y)" `alphaEqual` parseExpr "λy. y(λx. x)" |> not
prop> parseExpr "λy. y(λy. x)" `alphaEqual` parseExpr "λy. y(λx. x)" |> not
prop> parseExpr "λx. x(λz. y)" `alphaEqual` parseExpr " λz. z(λz. y)"
prop> x `alphaEqual` x
-}
alphaEqual :: Term -> Term -> Bool
alphaEqual (Var a) (Var b) = a == b
alphaEqual (Apply x1 x2) (Apply y1 y2) = x1 `alphaEqual` y1 && x2 `alphaEqual` y2
alphaEqual l1@(Abstr v1 _) (Abstr v2 e2) =
  not (v2 `S.member` freeVars l1) && l1 == Abstr v1 ((v2, Var v1) /: e2)
alphaEqual _ _ = False


subTerms :: Term -> S.Set Term
subTerms x@(Var _) = S.singleton x
subTerms l@(Abstr _ e) = S.insert l (subTerms e)
subTerms a@(Apply x y) = S.insert a (subTerms x `S.union` subTerms y)

instance Functor TermShape where
  fmap f x =
    case x of
      Var a -> Var (f a)
      Apply a b -> Apply (fmap f a) (fmap f b)
      Abstr v body -> Abstr (f v) (fmap f body)

-- common vars
_x,_y,_z,_u,_v,_w :: Term
(_x, _y, _z, _u, _v, _w) =
  (Var "x",Var "y",Var "z",Var "u",Var "v",Var "w")
