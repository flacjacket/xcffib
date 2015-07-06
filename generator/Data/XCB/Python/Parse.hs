{-
 - Copyright 2014 Tycho Andersen
 -
 - Licensed under the Apache License, Version 2.0 (the "License");
 - you may not use this file except in compliance with the License.
 - You may obtain a copy of the License at
 -
 -   http://www.apache.org/licenses/LICENSE-2.0
 -
 - Unless required by applicable law or agreed to in writing, software
 - distributed under the License is distributed on an "AS IS" BASIS,
 - WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 - See the License for the specific language governing permissions and
 - limitations under the License.
 -}
{-# LANGUAGE ViewPatterns #-}
module Data.XCB.Python.Parse (
  parseXHeaders,
  xform,
  renderPy,
  calcsize
  ) where

import Control.Applicative hiding (getConst)
import Control.Monad.State.Strict

import Data.Attoparsec.ByteString.Char8
import Data.Bits
import qualified Data.ByteString.Char8 as BS
import Data.List
import qualified Data.Map as M
import Data.Tree
import Data.Maybe
import Data.XCB.FromXML
import Data.XCB.Types as X
import Data.XCB.Python.PyHelpers

import Language.Python.Common as P

import System.FilePath
import System.FilePath.Glob

import Text.Printf

data TypeInfo =
  -- | A "base" X type, i.e. one described in baseTypeInfo; first arg is the
  -- struct.unpack string, second is the size.
  BaseType String |
  -- | A composite type, i.e. a Struct or Union created by XCB. First arg is
  -- the extension that defined it, second is the name of the type, third arg
  -- is the size if it is known.
  CompositeType String String
  deriving (Eq, Ord, Show)

type TypeInfoMap = M.Map X.Type TypeInfo

data BindingPart =
  Request (Statement ()) (Suite ()) |
  Declaration (Suite ()) |
  Noop
  deriving (Show)

collectBindings :: [BindingPart] -> (Suite (), Suite ())
collectBindings = foldr collectR ([], [])
  where
    collectR :: BindingPart -> (Suite (), Suite ()) -> (Suite (), Suite ())
    collectR (Request def decl) (defs, decls) = (def : defs, decl ++ decls)
    collectR (Declaration decl) (defs, decls) = (defs, decl ++ decls)
    collectR Noop x = x

data PackedElem =
  ElemPad String |
  ElemBase String String |
  ElemComposite String (Expr ()) |
  ElemList String (Expr ()) (Expr ()) (Maybe Int) |
  ElemExpr String String (Expr ()) |
  ElemValue String String String String
  deriving (Show)

parseXHeaders :: FilePath -> IO [XHeader]
parseXHeaders fp = do
  files <- namesMatching $ fp </> "*.xml"
  fromFiles files

renderPy :: Suite () -> String
renderPy s = ((intercalate "\n") $ map prettyText s) ++ "\n"

-- | Generate the code for a set of X headers. Note that the code is generated
-- in dependency order, NOT in the order you pass them in. Thus, you get a
-- string (a suggested filename) along with the python code for that XHeader
-- back.
xform :: [XHeader] -> [(String, Suite ())]
xform = map buildPython . dependencyOrder
  where
    buildPython :: Tree XHeader -> (String, Suite ())
    buildPython forest =
      let forest' = (mapM processXHeader $ postOrder forest)
          results = evalState forest' baseTypeInfo
      in last results
    processXHeader :: XHeader
                   -> State TypeInfoMap (String, Suite ())
    processXHeader header = do
      let imports = [mkImport "xcffib"]
          version = mkVersion header
          key = maybeToList $ mkKey header
          globals = [mkDict "_events", mkDict "_errors"]
          name = xheader_header header
          add = [mkAddExt header]
      parts <- mapM (processXDecl name) $ xheader_decls header
      let (requests, decls) = collectBindings parts
          ext = if length requests > 0
                then [mkClass (name ++ "Extension") "xcffib.Extension" requests]
                else []
      return $ (name, concat [imports, version, key, globals, decls, ext, add])
    -- Rearrange the headers in dependency order for processing (i.e. put
    -- modules which import others after the modules they import, so typedefs
    -- are propogated appropriately).
    dependencyOrder :: [XHeader] -> Forest XHeader
    dependencyOrder headers = unfoldForest unfold $ map xheader_header headers
      where
        headerM = M.fromList $ map (\h -> (xheader_header h, h)) headers
        unfold s = let h = headerM M.! s in (h, deps h)
        deps :: XHeader -> [String]
        deps = catMaybes . map matchImport . xheader_decls
        matchImport :: XDecl -> Maybe String
        matchImport (XImport n) = Just n
        matchImport _ = Nothing
    postOrder :: Tree a -> [a]
    postOrder (Node e cs) = (concat $ map postOrder cs) ++ [e]


mkAddExt :: XHeader -> Statement ()
mkAddExt (xheader_header -> "xproto") =
  flip StmtExpr () $ mkCall "xcffib._add_core" [ mkName "xprotoExtension"
                                               , mkName "Setup"
                                               , mkName "_events"
                                               , mkName "_errors"
                                               ]
mkAddExt header =
  let name = xheader_header header
  in flip StmtExpr () $ mkCall "xcffib._add_ext" [ mkName "key"
                                                 , mkName (name ++ "Extension")
                                                 , mkName "_events"
                                                 , mkName "_errors"
                                                 ]

-- | Information on basic X types.
baseTypeInfo :: TypeInfoMap
baseTypeInfo = M.fromList $
  [ (UnQualType "CARD8",    BaseType "B")
  , (UnQualType "uint8_t",  BaseType "B")
  , (UnQualType "CARD16",   BaseType "H")
  , (UnQualType "uint16_t", BaseType "H")
  , (UnQualType "CARD32",   BaseType "I")
  , (UnQualType "uint32_t", BaseType "I")
  , (UnQualType "CARD64",   BaseType "Q")
  , (UnQualType "uint64_t", BaseType "Q")
  , (UnQualType "INT8",     BaseType "b")
  , (UnQualType "int8_t",   BaseType "b")
  , (UnQualType "INT16",    BaseType "h")
  , (UnQualType "int16_t",  BaseType "h")
  , (UnQualType "INT32",    BaseType "i")
  , (UnQualType "int32_t",  BaseType "i")
  , (UnQualType "INT64",    BaseType "q")
  , (UnQualType "uint64_t", BaseType "q")
  , (UnQualType "BYTE",     BaseType "B")
  , (UnQualType "BOOL",     BaseType "B")
  , (UnQualType "char",     BaseType "c")
  , (UnQualType "void",     BaseType "c")
  , (UnQualType "float",    BaseType "f")
  , (UnQualType "double",   BaseType "d")
  ]

-- | Clone of python's struct.calcsize.
calcsize :: String -> Int
calcsize str = sum [fromMaybe 1 i * getSize c | (i, c) <- parseMembers str]
  where
    sizeM :: M.Map Char Int
    sizeM = M.fromList [ ('c', 1)
                       , ('B', 1)
                       , ('b', 1)
                       , ('H', 2)
                       , ('h', 2)
                       , ('I', 4)
                       , ('i', 4)
                       , ('Q', 8)
                       , ('q', 8)
                       , ('f', 4)
                       , ('d', 8)
                       , ('x', 1)
                       ]
    getSize = (M.!) sizeM

    parseMembers :: String -> [(Maybe Int, Char)]
    parseMembers s = case parseOnly lang (BS.pack s) of
                       Left err -> error ("can't calcsize " ++ s ++ " " ++ err)
                       Right xs -> xs

    lang = many $ (,) <$> optional decimal <*> (satisfy $ inClass $ M.keys sizeM)

xBinopToPyOp :: X.Binop -> P.Op ()
xBinopToPyOp X.Add = P.Plus ()
xBinopToPyOp X.Sub = P.Minus ()
xBinopToPyOp X.Mult = P.Multiply ()
xBinopToPyOp X.Div = P.FloorDivide ()
xBinopToPyOp X.And = P.BinaryAnd ()
xBinopToPyOp X.RShift = P.ShiftRight ()

xUnopToPyOp :: X.Unop -> P.Op ()
xUnopToPyOp X.Complement = P.Invert ()

xExpressionToNestedPyExpr :: (String -> String) -> XExpression -> Expr ()
xExpressionToNestedPyExpr acc (Op o e1 e2) =
  Paren (xExpressionToPyExpr acc (Op o e1 e2)) ()
xExpressionToNestedPyExpr acc xexpr =
  xExpressionToPyExpr acc xexpr

xExpressionToPyExpr :: (String -> String) -> XExpression -> Expr ()
xExpressionToPyExpr _ (Value i) = mkInt i
xExpressionToPyExpr _ (Bit i) = BinaryOp (ShiftLeft ()) (mkInt 1) (mkInt i) ()
xExpressionToPyExpr acc (FieldRef n) = mkName $ acc n
xExpressionToPyExpr _ (EnumRef _ n) = mkName n
xExpressionToPyExpr acc (PopCount e) =
  mkCall "xcffib.popcount" [xExpressionToPyExpr acc e]
-- http://cgit.freedesktop.org/xcb/proto/tree/doc/xml-xcb.txt#n290
xExpressionToPyExpr acc (SumOf n) = mkCall "sum" [mkName $ acc n]
xExpressionToPyExpr acc (Op o e1 e2) =
  let o' = xBinopToPyOp o
      e1' = xExpressionToNestedPyExpr acc e1
      e2' = xExpressionToNestedPyExpr acc e2
  in BinaryOp o' e1' e2' ()
xExpressionToPyExpr acc (Unop o e) =
  let o' = xUnopToPyOp o
      e' = xExpressionToNestedPyExpr acc e
  in Paren (UnaryOp o' e' ()) ()

getConst :: XExpression -> Maybe Int
getConst (Value i) = Just i
getConst (Bit i) = Just $ bit i
getConst (Op o e1 e2) = do
  c1 <- getConst e1
  c2 <- getConst e2
  return $ case o of
             X.Add -> c1 + c2
             X.Sub -> c1 - c2
             X.Mult -> c1 * c2
             X.Div -> c1 `quot` c2
             X.And -> c1 .&. c2
             X.RShift -> c1 `shift` c2
getConst (Unop o e) = do
  c <- getConst e
  return $ case o of
             X.Complement -> complement c
getConst (PopCount e) = fmap popCount $ getConst e
getConst _ = Nothing

xEnumElemsToPyEnum :: (String -> String) -> [XEnumElem] -> [(String, Expr ())]
xEnumElemsToPyEnum accessor membs = reverse $ conv membs [] [0..]
  where
    exprConv = xExpressionToPyExpr accessor
    conv :: [XEnumElem] -> [(String, Expr ())] -> [Int] -> [(String, Expr ())]
    conv ((EnumElem name expr) : els) acc is =
      let expr' = fromMaybe (mkInt (head is)) $ fmap exprConv expr
          is' = dropWhile (<= (fromIntegral (int_value expr'))) is
          acc' = (name, expr') : acc
      in conv els acc' is'
    conv [] acc _ = acc

-- Parse the GenStructElem's into a type that is easier to pack/unpack
parseStructElem :: String
                -> TypeInfoMap
                -> (String -> String)
                -> GenStructElem Type
                -> Maybe PackedElem

parseStructElem _ _ _ (Doc _ _ _) = Nothing
-- XXX: What does fd/switch mean? we should implement it correctly
parseStructElem _ _ _ (Fd _) = Nothing
parseStructElem _ _ _ (Switch _ _ _) = Nothing

parseStructElem _ _ _ (Pad i) = Just $ ElemPad $ mkPad i
-- The enum field is mostly for user information, so we ignore it.
parseStructElem ext m _ (X.List n typ len _) =
  let cons = case m M.! typ of
               BaseType c -> mkStr c
               CompositeType tExt c | ext /= tExt -> mkName $ tExt ++ "." ++ c
               CompositeType _ c -> mkName c
      attr = ((++) "self.")
      exprLen = fromMaybe pyNone $ fmap (xExpressionToPyExpr attr) len
      constLen = do
        l <- len
        getConst l
  in Just $ ElemList n cons exprLen constLen

-- The mask and enum fields are for user information, we can ignore them here.
parseStructElem ext m _ (SField n typ _ _) =
  let ret = case m M.! typ of
              BaseType c -> ElemBase n c
              CompositeType tExt c ->
                let c' = if tExt == ext then mkName c else mkDot tExt c
                in ElemComposite n c'
  in Just ret

parseStructElem _ m acc (ExprField n typ expr) =
  let e = (xExpressionToPyExpr acc) expr
      name' = acc n
  in case m M.! typ of
       BaseType c -> Just $ ElemExpr name' c e
       CompositeType _ _ -> Just $ ElemComposite name' e

-- As near as I can tell here the padding param is unused.
parseStructElem _ m acc (ValueParam typ mask _ list) =
  case m M.! typ of
    BaseType c ->
      let mask' = acc mask
          list' = acc list
      in Just $ ElemValue mask' list' c "I"
    CompositeType _ _ -> error (
      "ValueParams other than CARD{16,32} not allowed.")

-- Add the xcb_generic_{request,reply}_t structure data to the beginning of a
-- pack string. This is a little weird because both structs contain a one byte
-- pad which isn't at the end. If the first element of the request or reply is
-- a byte long, it takes that spot instead, and there is one less offset
addStructData :: String -> String -> String
addStructData prefix (c : cs) | c `elem` "Bbx" =
  let result = maybePrintChar prefix c
  in if result == prefix then result ++ (c : cs) else result ++ cs
addStructData prefix s = (maybePrintChar prefix 'x') ++ s

maybePrintChar :: String -> Char -> String
maybePrintChar s c | "%c" `isInfixOf` s = printf s c
maybePrintChar s _ = s

-- Don't prefix a single pad byte with a '1'. This is simpler to parse
-- visually, and also simplifies addStructData above.
mkPad :: Int -> String
mkPad 1 = "x"
mkPad i = (show i) ++ "x"


packer :: Suite ()
packer = [mkAssign "packer" (mkCall "xcffib.Packer" noArgs)]

mkPackStmts :: String
            -> String
            -> TypeInfoMap
            -> (String -> String)
            -> String
            -> [GenStructElem Type]
            -> ([String], Suite ())
mkPackStmts ext name m accessor prefix membs =
  let elems = mapMaybe (parseStructElem ext m id) membs
      -- First we'll separate the explicit and implicit packs, and pack them
      (expl, imp) = partition isExplicit elems
      (expArgs, expPacks) = let (as, ks) = unzip $ map packExplicit expl in (catMaybes as, ks)
      imp' = concat $ map (packImplicit accessor) imp

      -- In some cases (e.g. xproto.ConfigureWindow) there is padding after
      -- value_mask. The way the xml specification deals with this is by
      -- specifying value_mask in both the regular pack location as well as
      -- implying it implicitly. Thus, we want to make sure that if we've already
      -- been told to pack something explcitly, that we don't also pack it
      -- implicitly.
      (impArgs, impStmt) = unzip $ filter (flip notElem expArgs . fst) imp'

      impArgs' = case (ext, name) of
                   -- XXX: QueryTextExtents has a field named "odd_length" with a
                   -- fieldref of "string_len", so we fix it up here to match.
                   ("xproto", "QueryTextExtents") ->
                     let replacer "odd_length" = "string_len"
                         replacer s = s
                     in map replacer impArgs
                   _ -> impArgs
      impStmt' = concat impStmt

      packStr = addStructData prefix $ concat expPacks
      write = mkCall "packer.pack" $ mkStr ('=' : packStr) : (map (mkName . accessor) expArgs)
      expStmt = if length packStr > 0 then [StmtExpr write ()] else []
  in (expArgs ++ impArgs', expStmt ++ impStmt')
    where
      isExplicit :: PackedElem -> Bool
      isExplicit (ElemPad _) = True
      isExplicit (ElemBase _ _) = True
      isExplicit _ = False

      packExplicit :: PackedElem
                   -> (Maybe String, String)
      packExplicit (ElemBase n c) = (Just n, c)
      packExplicit (ElemPad c) = (Nothing, c)
      packExplicit _ = error "Not explicitly packed"

      packImplicit :: (String -> String)
                   -> PackedElem
                   -> [(String, Suite ())]

      packImplicit acc (ElemComposite n _) =
         -- XXX: be a little smarter here? we should really make sure that things
         -- have a .pack(); if users are calling us via the old style api, we need
         -- to support that as well. This isn't super necessary, though, because
         -- currently (xcb-proto 1.10) there are no direct packs of raw structs, so
         -- this is really only necessary if xpyb gets forward ported in the future if
         -- there are actually calls of this type.
        let comp = flip StmtExpr () $ mkCall "packer.write" [mkCall (acc n ++ ".pack") noArgs]
        in [(n, [comp])]

      -- TODO: assert values are in enum?
      packImplicit acc (ElemList n cons _ _) =
        let list = flip StmtExpr () $ mkCall "packer.pack_list" [ mkName (acc n)
                                                                , cons
                                                                ]
        in [(n, [list])]

      packImplicit _ (ElemExpr n c e) =
        let expr = flip StmtExpr () $ mkCall "packer.pack" [mkStr ('=' : c), e]
        in [(n, [expr])]

      packImplicit acc (ElemValue mask list c c') =
        let mask' = flip StmtExpr () $ mkCall "packer.pack" [ mkStr ('=' : c)
                                                            , mkName mask]
            list' = flip StmtExpr () $ mkCall "packer.pack_list" [ mkName (acc list)
                                                                 , mkStr c'
                                                                 ]
        in [(mask, [mask']), (list, [list'])]
      packImplicit _ _ = error "Not implicitly packed"

mkPackMethod :: String
             -> String
             -> TypeInfoMap
             -> Maybe (String, Int)
             -> [GenStructElem Type]
             -> Maybe Int
             -> Statement ()
mkPackMethod ext name m prefixAndOp structElems minLen =
  let acc = (++) "self."
      (prefix, op) = case prefixAndOp of
                        Just ('x' : rest, i) ->
                          let write = mkKwCall "packer.pack" [mkStr "=B", mkInt i] [ident "align"] [mkInt 1]
                          in (rest, [StmtExpr write ()])
                        Just (rest, _) -> error ("internal API error: " ++ show rest)
                        Nothing -> ("", [])
      (_, packStmts) = mkPackStmts ext name m acc prefix structElems
      extend = concat $ do
        len <- maybeToList minLen
        let bufLen = mkName "buf_len"
            bufLenAssign = mkAssign bufLen $ mkCall "len" [mkCall "packer.getvalue" noArgs]
            test = (BinaryOp (LessThan ()) bufLen (mkInt len)) ()
            bufWriteLen = Paren (BinaryOp (Minus ()) (mkInt 32) bufLen ()) ()
            writeExtra = [StmtExpr (mkCall "packer.pack" [repeatStr "x" bufWriteLen]) ()]
        return $ [bufLenAssign, mkIf test writeExtra]
      ret = [mkReturn $ mkCall "packer.getvalue" noArgs]
  --in mkMethod "pack" (mkParams ["self"]) $ buf ++ op ++ packStmts ++ extend ++ ret
  in mkMethod "pack" (mkParams ["self"]) $ packer ++ op ++ packStmts ++ extend ++ ret

data StructUnpackState = StructUnpackState {
  -- | stNeedsPad is whether or not a type_pad() is needed. As near
  -- as I can tell the conditions are:
  --    1. a list was unpacked
  --    2. a struct was unpacked
  -- ListFontsWithInfoReply is an example of a struct which has lots of
  -- this type of thing.
  stNeedsPad :: Bool,

  -- The list of names the struct.pack accumulator has, and the
  stNames :: [String],

  -- The list of pack directives (potentially with a "%c" in it for
  -- the prefix byte).
  stPacks :: String
}


-- Make a struct style (i.e. not union style) unpack.
mkUnpack :: String
         -> String
         -> TypeInfoMap
         -> Expr ()
         -> [GenStructElem Type]
         -> (Suite (), Maybe Int)
mkUnpack prefix ext m unpacker membs =
  let elems = mapMaybe (parseStructElem ext m id) membs
      initial = StructUnpackState False [] prefix
      (_, unpackStmts, size) = evalState (mkUnpackStmts unpacker elems) initial
      unpacker_offset = mkDot unpacker "offset"
      base = [mkAssign "base" unpacker_offset]
      bufsize =
        let rhs = BinaryOp (Minus ()) unpacker_offset (mkName "base") ()
        in [mkAssign (mkAttr "bufsize") rhs]
      statements = base ++ unpackStmts ++ bufsize
  in (statements, size)

    where

      -- Apparently you only type_pad before unpacking Structs or Lists, never
      -- base types.
      mkUnpackStmts :: Expr ()
                    -> [PackedElem]
                    -> State StructUnpackState ([String], Suite (), Maybe Int)

      mkUnpackStmts _ [] = flushAcc

      mkUnpackStmts unpacker' ((ElemPad pack) : xs) = do
        st <- get
        let packs = if "%c" `isInfixOf` (stPacks st)
                    then addStructData (stPacks st) pack
                    else (stPacks st) ++ pack
        put $ st { stPacks = packs }
        mkUnpackStmts unpacker' xs

      mkUnpackStmts unpacker' ((ElemBase name pack) : xs) = do
        st <- get
        let packs = if "%c" `isInfixOf` (stPacks st)
                    then addStructData (stPacks st) pack
                    else (stPacks st) ++ pack
        put $ st { stNames = stNames st ++ [name]
                 , stPacks = packs
                 }
        mkUnpackStmts unpacker' xs

      mkUnpackStmts unpacker' ((ElemComposite name pack) : xs) = do
        (packNames, packStmt, _) <- flushAcc
        st <- get
        put $ st { stNeedsPad = True }
        let pad = if stNeedsPad st
                  then [typePad unpacker' pack]
                  else []
        (restNames, restStmts, _) <- mkUnpackStmts unpacker' xs
        let comp = mkCall pack [unpacker']
            compStmt = mkAssign (mkAttr name) comp
        return ( packNames ++ [name] ++ restNames
               , packStmt ++ pad ++ compStmt : restStmts
               , Nothing
               )

      mkUnpackStmts unpacker' ((ElemList name cons listLen constLen) : xs) = do
        (packNames, packStmt, packSz) <- flushAcc
        st <- get
        put $ st { stNeedsPad = True }
        let pad = if stNeedsPad st
                  then [typePad unpacker' cons]
                  else []
        (restNames, restStmts, restSz) <- mkUnpackStmts unpacker' xs
        let list = mkCall "xcffib.List" [ unpacker'
                                        , cons
                                        , listLen
                                        ]
            totalSize = do
                          before <- packSz
                          rest <- restSz
                          constLen' <- constLen
                          return $ before + rest + constLen'
            listStmt = mkAssign (mkAttr name) list
        return ( packNames ++ [name] ++ restNames
               , packStmt ++ pad ++ listStmt : restStmts
               , totalSize
               )

      mkUnpackStmts _ ((ElemExpr _ _ _) : _) = error "Only valid for requests"
      mkUnpackStmts _ ((ElemValue _ _ _ _) : _) = error "Only valid for requests"

      flushAcc :: State StructUnpackState ([String], Suite (), Maybe Int)
      flushAcc = do
        StructUnpackState needsPad args keys <- get
        let size = calcsize keys
            assign = mkUnpackFrom "unpacker" args keys
        put $ StructUnpackState needsPad [] ""
        return (args, assign, Just size)

      typePad unpacker' e = StmtExpr (mkCall (mkDot unpacker' "pad") [e]) ()

-- | Given a (qualified) type name and a target type, generate a TypeInfoMap
-- updater.
mkModify :: String -> String -> TypeInfo -> TypeInfoMap -> TypeInfoMap
mkModify ext name ti =
  let m' = M.fromList [ (UnQualType name, ti)
                      , (QualType ext name, ti)
                      ]
  in flip M.union m'

processXDecl :: String
             -> XDecl
             -> State TypeInfoMap BindingPart
processXDecl ext (XTypeDef name typ) =
  do modify $ \m -> mkModify ext name (m M.! typ) m
     return Noop
processXDecl ext (XidType name) =
  -- http://www.markwitmer.com/guile-xcb/doc/guile-xcb/XIDs.html
  do modify $ mkModify ext name (BaseType "I")
     return Noop
processXDecl _ (XImport n) =
  return $ Declaration [ mkRelImport n]
processXDecl _ (XEnum name membs) =
  return $ Declaration [mkEnum name $ xEnumElemsToPyEnum id membs]
processXDecl ext (XStruct n membs) = do
  m <- get
  let unpacker = mkName "unpacker"
      (statements, len) = mkUnpack "" ext m unpacker membs
      pack = mkPackMethod ext n m Nothing membs Nothing
      fixedLength = maybeToList $ do
        theLen <- len
        let rhs = mkInt theLen
        return $ mkAssign "fixed_size" rhs
  modify $ mkModify ext n (CompositeType ext n)
  return $ Declaration [mkXClass n "xcffib.Struct" statements (pack : fixedLength)]
processXDecl ext (XEvent name opcode membs noSequence) = do
  m <- get
  let unpacker = mkName "unpacker"
      cname = name ++ "Event"
      prefix = if fromMaybe False noSequence then "x" else "x%c2x"
      pack = mkPackMethod ext name m (Just (prefix, opcode)) membs (Just 32)
      (statements, _) = mkUnpack prefix ext m unpacker membs
      eventsUpd = mkDictUpdate "_events" opcode cname
  return $ Declaration [ mkXClass cname "xcffib.Event" statements [pack]
                       , eventsUpd
                       ]
processXDecl ext (XError name opcode membs) = do
  m <- get
  let unpacker = mkName "unpacker"
      cname = name ++ "Error"
      prefix = "xx2x"
      pack = mkPackMethod ext name m (Just (prefix, opcode)) membs Nothing
      (statements, _) = mkUnpack prefix ext m unpacker membs
      errorsUpd = mkDictUpdate "_errors" opcode cname
      alias = mkAssign ("Bad" ++ name) (mkName cname)
  return $ Declaration [ mkXClass cname "xcffib.Error" statements [pack]
                       , alias
                       , errorsUpd
                       ]
processXDecl ext (XRequest name opcode membs reply) = do
  m <- get
  let
      -- xtest doesn't seem to use the same packing strategy as everyone else,
      -- but there is no clear indication in the XML as to why that is. yay.
      prefix = if ext == "xtest" then "xx2x" else "x%c2x"
      (args, packStmts) = mkPackStmts ext name m id prefix membs
      cookieName = (name ++ "Cookie")
      replyDecl = concat $ maybeToList $ do
        reply' <- reply
        let unpacker = mkName "unpacker"
            (replyStmts, _) = mkUnpack "x%c2x4x" ext m unpacker reply'
            replyName = name ++ "Reply"
            theReply = mkXClass replyName "xcffib.Reply" replyStmts []
            replyType = mkAssign "reply_type" $ mkName replyName
            cookie = mkClass cookieName "xcffib.Cookie" [replyType]
        return [theReply, cookie]

      hasReply = if length replyDecl > 0
                 then [ArgExpr (mkName cookieName) ()]
                 else []
      isChecked = pyTruth $ isJust reply
      argChecked = ArgKeyword (ident "is_checked") (mkName "is_checked") ()
      checkedParam = Param (ident "is_checked") Nothing (Just isChecked) ()
      allArgs = (mkParams $ "self" : args) ++ [checkedParam]
      mkArg = flip ArgExpr ()
      ret = mkReturn $ mkCall "self.send_request" ((map mkArg [ mkInt opcode
                                                              , mkName "packer"
                                                              ])
                                                              ++ hasReply
                                                              ++ [argChecked])
      requestBody = packer ++ packStmts ++ [ret]
      request = mkMethod name allArgs requestBody
  return $ Request request replyDecl
processXDecl ext (XUnion name membs) = do
  m <- get
  let elems = mapMaybe (parseStructElem ext m id) membs
      toUnpack = map mkUnionUnpack elems
      -- Here, we only want to pack the first member of the union, since every
      -- member is the same data and we don't want to repeatedly pack it.
      pack = mkPackMethod ext name m Nothing [head membs] Nothing
      decl = [mkXClass name "xcffib.Union" toUnpack [pack]]
  modify $ mkModify ext name (CompositeType ext name)
  return $ Declaration decl
  where
    unpackerCopy = mkCall "unpacker.copy" noArgs

    mkUnionUnpack :: PackedElem
                  -> Statement ()
    mkUnionUnpack (ElemList n cons listLen _) =
      let list = mkCall "xcffib.List" [ unpackerCopy
                                      , cons
                                      , listLen
                                      ]
      in mkAssign (mkAttr n) list
    mkUnionUnpack (ElemComposite n c) =
      let comp = mkCall c [unpackerCopy]
      in mkAssign (mkAttr n) comp
    mkUnionUnpack _ = error "Unable to Union unpack this type"

processXDecl ext (XidUnion name _) =
  -- These are always unions of only XIDs.
  do modify $ mkModify ext name (BaseType "I")
     return Noop

mkVersion :: XHeader -> Suite ()
mkVersion header =
  let major = ver "MAJOR_VERSION" (xheader_major_version header)
      minor = ver "MINOR_VERSION" (xheader_minor_version header)
  in major ++ minor
  where
    ver :: String -> Maybe Int -> Suite ()
    ver target i = maybeToList $ fmap (\x -> mkAssign target (mkInt x)) i

mkKey :: XHeader -> Maybe (Statement ())
mkKey header = do
  name <- xheader_xname header
  let call = mkCall "xcffib.ExtensionKey" [mkStr name]
  return $ mkAssign "key" call
