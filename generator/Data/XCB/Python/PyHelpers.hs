{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
module Data.XCB.Python.PyHelpers (
  mkImport,
  mkInt,
  mkAssign,
  mkCall,
  noArgs,
  mkEnum,
  mkName,
  mkDot,
  mkAttr,
  mkIncr,
  mkClass,
  mkEmptyClass,
  mkXClass,
  mkStr,
  mkUnpackFrom,
  mkDict,
  mkDictUpdate,
  mkMethod,
  mkReturn,
  pyTruth,
  mkParams,
  ident,
  pyNone
  ) where

import Data.List.Split
import Data.Maybe

import Language.Python.Common

_reserved :: [String]
_reserved = [ "None"
            , "def"
            , "class"
            , "and"
            , "or"
            ]


-- | Create and sanatize a python identifier.
ident :: String -> Ident ()
ident s | s `elem` _reserved = Ident ("_" ++ s) ()
ident s | isInt s = Ident ("_" ++ s) ()
  where
    isInt str = isJust $ ((maybeRead str) :: Maybe Int)
    maybeRead = fmap fst . listToMaybe . reads
ident s = Ident s ()

-- Make a DottedName out of a string like "foo.bar" for use in imports.
mkDottedName :: String -> DottedName ()
mkDottedName = map ident . splitOn "."

mkVar :: String -> Expr ()
mkVar name = Var (ident name) ()

-- | Make an Expr out of a string like "foo.bar" describing the name.
mkName :: String -> Expr ()
mkName s =
  let strings = map mkVar $ reverse $ splitOn "." s
  in foldr mkDot (head strings) (reverse $ tail strings)

mkDot :: Expr () -> Expr () -> Expr ()
mkDot e1 e2 = BinaryOp (Dot ()) e1 e2 ()

-- | Make an attribute access, i.e. self.<string>.
mkAttr :: String -> Expr ()
mkAttr s = mkName ("self." ++ s)

mkImport :: String -> Statement ()
mkImport name = Import [ImportItem (mkDottedName name) Nothing ()] ()

mkInt :: Int -> Expr ()
mkInt i = Int (toInteger i) (show i) ()

class PseudoExpr a where
  getExpr :: a -> Expr ()

instance PseudoExpr String where
  getExpr s = mkName s
instance PseudoExpr (Expr ()) where
  getExpr = id

mkAssign :: PseudoExpr a => a -> Expr () -> Statement ()
mkAssign name expr = Assign [getExpr name] expr ()

mkIncr :: String -> Expr () -> Statement ()
mkIncr name expr = AugmentedAssign (mkName name) (PlusAssign ()) expr ()

class PseudoArgument a where
  getArgument :: a -> Argument ()

instance PseudoArgument (Expr ()) where
  getArgument p = ArgExpr p ()
instance PseudoArgument (Argument ()) where
  getArgument = id

mkCall :: (PseudoExpr a, PseudoArgument b) => a -> [b] -> Expr ()
mkCall name args = Call (getExpr name) (map getArgument args) ()

noArgs :: [Argument ()]
noArgs = []

mkEnum :: String -> [(String, Expr ())] -> Statement ()
mkEnum cname values =
  let body = map (uncurry mkAssign) values
  in Class (Ident cname ()) [] body ()

mkParams :: [String] -> [Parameter ()]
mkParams = map (\x -> Param (ident x) Nothing Nothing ())

mkArg :: String -> Argument ()
mkArg n = ArgExpr (mkName n) ()

mkXClass :: String -> String -> Suite () -> Suite () -> Statement ()
mkXClass clazz superclazz [] [] = mkEmptyClass clazz superclazz
mkXClass clazz superclazz constructor methods =
  let args = [ "self", "unpacker" ]
      super = mkCall (superclazz ++ ".__init__") $ map mkName args
      body = [(StmtExpr super ())] ++ constructor
      initParams = mkParams args
      initMethod = Fun (ident "__init__") initParams Nothing body ()
  in mkClass clazz superclazz $ initMethod : methods

mkEmptyClass :: String -> String -> Statement ()
mkEmptyClass clazz superclazz = mkClass clazz superclazz [Pass ()]

mkClass :: String -> String -> Suite () -> Statement ()
mkClass clazz superclazz body = Class (ident clazz) [mkArg superclazz] body ()

mkStr :: String -> Expr ()
mkStr s = Strings ["\"", s, "\""] ()

mkTuple :: [Expr ()] -> Expr ()
mkTuple = flip Tuple ()

mkUnpackFrom :: [String] -> String -> Bool -> Statement ()
mkUnpackFrom names packs isUnion =
  let lhs = mkTuple $ map mkAttr names
      -- Don't span with this default arg unless it is really necessary.
      increment = if isUnion then [pyTruth False] else []
      rhs = mkCall "unpacker.unpack" $ mkStr packs : increment
  in mkAssign lhs rhs

mkDict :: String -> Statement ()
mkDict name = mkAssign name (Dictionary [] ())

mkDictUpdate :: String -> Int -> String -> Statement ()
mkDictUpdate dict key value =
  mkAssign (Subscript (mkName dict) (mkInt key) ()) (mkName value)

mkMethod :: String -> [Parameter ()] -> Suite () -> Statement ()
mkMethod name args body = Fun (ident name) args Nothing body ()

mkReturn :: Expr () -> Statement ()
mkReturn = flip Return () . Just

pyTruth :: Bool -> Expr ()
pyTruth = flip Bool ()

pyNone :: Expr ()
pyNone = None ()
