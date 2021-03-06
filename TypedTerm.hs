{-#LANGUAGE FlexibleInstances, TypeSynonymInstances #-}


module TypedTerm
    (
      tyVar, (~>), TyTerm,
      inferType, showTypeTree, inferThenShow,
      TyConstraintTree, NamedType, NamedTyTerm, inferTypeWithConstriant, inferConstraintShow
    ) where

import LambdaTerm
import qualified Data.Map as M
import Control.Monad.State
import Test.QuickCheck(Arbitrary(..), choose, Gen)
import Control.Applicative
import MyOps
import Data.Maybe (fromMaybe)
import qualified Data.Set as S

{- $setup
>>> import Test.QuickCheck
>>> import Parse
-}

newtype TyId = TyId Int
  deriving (Ord, Eq)

instance Show TyId where
  show (TyId i) = "t" ++ show i

type Type = TypeShape TyId

data TypeShape a = TyVar a
                 | TyArrow (TypeShape a) (TypeShape a)
                 deriving (Eq, Ord)

isArrow :: TypeShape a -> Bool
isArrow (TyArrow _ _) = True
isArrow _ = False

instance Show Type where
  show = showTypeShape show

instance Show (NamedType) where
  show = showTypeShape id

showTypeShape :: (a -> String) -> TypeShape a -> String
showTypeShape toStr t =
  case t of
    (TyVar tid) -> toStr tid
    (TyArrow t1 t2) -> surroundString (isArrow t1) (showTypeShape toStr t1) ++ " → " ++ showTypeShape toStr t2

instance Functor TypeShape where
  fmap f (TyVar a) = TyVar (f a)
  fmap f (TyArrow a b) = TyArrow (fmap f a) (fmap f b)


infixr 9 ~>
(~>) :: TypeShape t -> TypeShape t -> TypeShape t
t1 ~> t2 = TyArrow t1 t2

tyVar :: a -> TypeShape a
tyVar = TyVar

tyId :: Int -> Type
tyId i = TyVar (TyId i)

instance Arbitrary TyId where
  arbitrary = TyId <$> choose(1,8)

instance Arbitrary a => Arbitrary (TypeShape a) where
  arbitrary = do
    i <- choose(1::Int,4)
    if i == 1
    then liftM2 (~>) arbitrary arbitrary
    else TyVar <$> arbitrary


data TyEnv = TyEnv {
  varMap :: M.Map VarName Type,
  envIndex :: Int,
  typeMap :: M.Map TyId Type
} deriving (Eq, Show)

updateVarMap :: TyEnv -> M.Map VarName Type -> TyEnv
updateVarMap (TyEnv _ i tm) m' = TyEnv m' i tm

instance Arbitrary TyEnv where
  arbitrary = do
    size <- choose(0,8) :: Gen Int
    list <- [0..size]
              |> map (\_ -> (,) <$> (getVarString <$> arbitrary) <*> (arbitrary :: Gen Type))
              |> sequenceA
    return $ TyEnv (M.fromList list) size M.empty

singletonEnv :: VarName -> Type -> TyEnv
singletonEnv k v = TyEnv (M.singleton k v) 0 M.empty

emptyEnv :: TyEnv
emptyEnv = TyEnv M.empty 0 M.empty

lookupEnv :: VarName -> TyEnv -> Maybe Type
lookupEnv term env = M.lookup term (varMap env)

newIdFromEnv :: EnvCanFail TyId
newIdFromEnv = do
  (TyEnv m i tm) <- get
  put (TyEnv m (i+1) tm)
  return $ TyId (i+1)

newTyVarFromEnv :: EnvCanFail Type
newTyVarFromEnv = TyVar <$> newIdFromEnv

type EnvCanFail a = StateT TyEnv Mayfail a

type TyTerm = TermShape Type

inferThenShow :: Term -> String
inferThenShow term =
  case inferType term of
    Left msg -> msg
    Right (tp, tpTree) -> showTypeTree term tpTree ++ " : " ++ show tp

inferConstraintShow :: Term -> TyConstraintTree -> String
inferConstraintShow term ctree =
  case inferTypeWithConstriant term ctree of
    Left msg -> msg
    Right (tp, tpTree) -> showTypeTree term tpTree ++ " : " ++ show tp

showTypeTree :: Term -> NamedTyTerm -> String
showTypeTree term tree =
  case (term, tree) of
    (Var v, Var t) -> "{" ++ v ++ ": " ++ show t ++ "}"
    (Apply x y, Apply tx ty) -> surroundAbstr x tx ++ " " ++ surroundNonPrim y ty
    (Abstr v body, Abstr tv tbody) -> "λ" ++ v ++ ": " ++ show tv ++ showBody
      where showBody = " . " ++ showTypeTree body tbody
  where surroundNonPrim x tp =
          if isPrim x then showTypeTree x tp else "(" ++ showTypeTree x tp ++ ")"
        surroundAbstr l@(Abstr _ _) tp = "(" ++ showTypeTree l tp ++ ")"
        surroundAbstr other tp = showTypeTree other tp

inferType :: Term -> Mayfail (NamedType, NamedTyTerm)
inferType term = inferTypeWithConstriant term (const Nothing <$> term)

inferTypeWithConstriant :: Term -> TyConstraintTree -> Mayfail (NamedType, NamedTyTerm)
inferTypeWithConstriant term ctree = do
  (ty, tyTerm) <- cleanTree <$> runStateT (inferInEnv term initType [term]) emptyEnv
  nameMap <- constraintTerm ctree tyTerm
  return (toNamedType nameMap ty, toNamedType nameMap <$> tyTerm)
  where initType = tyId 0
        cleanTree ((tp, tree), env) = (updateType tp , updateType <$> tree)
          where
            updateType = remapId . replace
            replace oldType =
              rebuildType rebFunc oldType |> fromMaybe (error "rebuild failed")
                where rebFunc v@(TyVar vid) =
                        Just $ fromMaybe v (M.lookup vid (typeMap env) >>= rebuildType rebFunc)
                      rebFunc _ = Nothing
            neatIdMap = mkIdRemap (envIndex env) (M.keysSet $ typeMap env)
            mapId i = fromMaybe (error "no key") (M.lookup i neatIdMap)
            remapId t = mapId <$> t
        toNamedType :: M.Map TyId NamedType -> Type -> NamedType
        toNamedType nameMap t = rebuildType repId t |> fromMaybe (error "replace id failed")
          where
            repId v@(TyVar vid) =
              Just $ fromMaybe (TyVar $ show v) (M.lookup vid nameMap)
            repId _ = Nothing

type Trace = [Term]

inferInEnv :: Term -> Type -> Trace -> EnvCanFail (Type, TyTerm)
inferInEnv term reqType trace =
  case term of
    Apply term1 term2 -> do
      newType <- newTyVarFromEnv
      (type2, tree2) <- inferInEnv term2 newType (term2: trace)
      (TyArrow _ whole, tree1) <- inferInEnv term1 (type2 ~> reqType) (term1: trace)
      return (whole, Apply tree1 tree2)
    Var name -> do
      env <- get
      case lookupEnv name env of
        Nothing -> do
          updateEnvVar name reqType
          return (reqType, Var reqType)
        Just oldType -> do
          m <- mergeTypesOfTerm oldType reqType
          return (m, Var m)
    Abstr v body -> do
      varType <- newTyVarFromEnv
      bType <- newTyVarFromEnv
      oldEnv <- get
      updateEnvVar v varType
      (bType', btree) <- inferInEnv body bType (body: trace)
      totalType <- mergeTypesOfTerm (varType ~> bType') reqType
      case lookupEnv v oldEnv of
        Just oldType -> updateEnvVar v oldType
        Nothing -> deleteEnvVar v
      return (totalType, Abstr varType btree)
  where
    mergeTypesOfTerm t1 t2 = StateT $ \env ->
      case runStateT (mergeTypes t1 t2) env of
        Left msg -> Left (msg ++ traceMsg)
        ok -> ok
    traceMsg = (\t -> "\n\tin " ++ prettyShow t) <$> trace |> concat


-- | change a 'VarName''s 'Type' in env
-- prop> execStateT (updateEnvVar "a" x) emptyEnv == good (singletonEnv "a" x)
-- prop> execStateT (updateEnvVar "a" x) (singletonEnv "a" y) == good (singletonEnv "a" x)
updateEnvVar :: VarName -> Type -> EnvCanFail ()
updateEnvVar term newT = do
  (TyEnv m i tm) <- get
  put $ TyEnv (M.insert term newT m) i tm

deleteEnvVar :: VarName -> EnvCanFail ()
deleteEnvVar v = do
  env <- get
  put $ env `updateVarMap` M.delete v (varMap env)

-- | change all type vars of one specific id in the env to another term
-- prop> let mkEnv = singletonEnv "a" in (varMap <$> execStateT (updateEnvType (TyId 1) randT) (mkEnv (tyId 1))) == return (varMap $ mkEnv randT)
-- prop> let mkEnv = singletonEnv "a" in (varMap <$> execStateT (updateEnvType (TyId 2) randT) (mkEnv (tyId 1))) == return (varMap $ mkEnv (tyId 1))
-- prop> let {mkEnv = singletonEnv "a"; i1 = (TyId 1)} in (varMap <$> execStateT (updateEnvType i1 randT) (mkEnv (tyId 1 ~> tyId 1))) == return (varMap $ mkEnv (randT ~> randT))
updateEnvType :: TyId -> Type -> EnvCanFail ()
updateEnvType i1 (TyVar i2) | i1 == i2 = return ()
updateEnvType tid tp = do
  env <- get
  put $ TyEnv (updateType <$> varMap env) (envIndex env) (M.insert tid tp $ typeMap env)
  where
    updateType = rebuildType rebFunc /> fromMaybe (error "rebuild failed")
    rebFunc v@(TyVar vid)
      | vid==tid = Just tp
      | otherwise = Just v
    rebFunc _ = Nothing

{- | try to merge two compatible types into one
prop> runStateT (mergeTypes (TyVar v) (TyVar v)) randEnv == good (TyVar v, randEnv)
prop> \v1 v2 v3 randEnv -> v3/=v1&&v2/=v3 ==> let arrow = (TyVar v1 ~> TyVar v2) in (evalStateT (mergeTypes (TyVar v3) arrow) randEnv == good arrow) && (evalStateT (mergeTypes arrow (TyVar v3)) randEnv == good arrow)
prop> \v1 v2 v3 v4 v5 v6 randEnv -> v4/=v1 && v5/=v1 && v6/=v2 && v6/=v3 ==> let {a1 = (TyVar v1 ~> (TyVar v2 ~> TyVar v3)); a2 = ((TyVar v4 ~> TyVar v5) ~> TyVar v6)} in evalStateT (mergeTypes a1 a2) randEnv == good ((TyVar v4 ~> TyVar v5) ~> (TyVar v2 ~> TyVar v3))
-}
mergeTypes :: Type -> Type -> EnvCanFail Type
mergeTypes t1@(TyVar i1) t2
  | t2 == t1 = return t1
  | t2 `constainTyId` i1 =
    lift $ wrong $ "can't construct infinite type: " ++ show t1 ++ " = " ++ show t2
  | otherwise = do
    updateEnvType i1 t2
    return t2
mergeTypes arrow@(TyArrow t1 t2) term2 =
  case term2 of
    TyVar _ -> mergeTypes term2 arrow
    TyArrow t3 t4 -> do
      ltype <- mergeTypes t1 t3
      rtype <- mergeTypes t2 t4
      return $ ltype ~> rtype

rebuildType :: Alternative m => (TypeShape a -> m (TypeShape b)) -> TypeShape a -> m (TypeShape b)
rebuildType fm v@(TyVar _) = fm v
rebuildType fm a@(TyArrow t1 t2) =
  fm a <|> TyArrow <$> rebuildType fm t1 <*> rebuildType fm t2

constainTyId :: Type -> TyId -> Bool
constainTyId (TyVar ix) iy = ix == iy
constainTyId (TyArrow a b) i = a `constainTyId` i || b `constainTyId` i

mkIdRemap :: Int -> S.Set TyId -> M.Map TyId TyId
mkIdRemap maxId excludes =
  let keysLeft = S.fromList (TyId <$> [0..maxId]) `S.difference` excludes
  in M.fromList $ zip (S.toList keysLeft) (TyId <$> [0..])

-- | represent a partially-typed constraint of a term
type NamedType = TypeShape String
type TyConstraintTree = TermShape (Maybe NamedType)
type NamedTyTerm = TermShape NamedType

constraintTerm :: TyConstraintTree -> TyTerm -> Mayfail (M.Map TyId NamedType)
constraintTerm ctree tree =
  case (ctree, tree) of
    (Var (Just rt), Var t) -> constraintType t rt
    (Var Nothing, _) -> good M.empty
    (Apply rt1 rt2, Apply t1 t2) -> do
      result1 <- constraintTerm rt1 t1
      result2 <- constraintTerm rt2 t2
      tryMergeMaps result1 result2
    (Abstr (Just rvt) rbodyt, Abstr vt bodyt) -> do
      result1 <- constraintType vt rvt
      result2 <-  constraintTerm rbodyt bodyt
      tryMergeMaps result1 result2
    (Abstr Nothing rbodyt, Abstr _ bodyt) ->
      constraintTerm rbodyt bodyt
    _ -> wrong "constraint shape not match!"


constraintType :: Type -> NamedType -> Mayfail (M.Map TyId NamedType)
constraintType t1@(TyVar i1) t2 =
  return $ M.singleton i1 t2
constraintType arrow@(TyArrow t1 t2) term2 =
  case term2 of
    TyVar _ -> wrong $ "type " ++ show arrow ++ " can't be constraint to " ++ show term2
    TyArrow t3 t4 -> do
      l <- constraintType t1 t3
      r <- constraintType t2 t4
      tryMergeMaps l r

tryMergeMaps :: (Ord k, Eq a, Show a) => M.Map k a -> M.Map k a -> Either String (M.Map k a)
tryMergeMaps m1 m2 = m1 |> M.toList |> foldr foldF (good m2)
  where foldF (k, a) acc = do
          accmap <- acc
          case M.lookup k accmap of
            Nothing -> return $ M.insert k a accmap
            Just b -> if a==b then acc
                      else wrong $ show a ++ " can't be " ++ show b
