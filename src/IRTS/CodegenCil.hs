{-# LANGUAGE RecordWildCards, OverloadedStrings, OverloadedLists #-}
module IRTS.CodegenCil where

import           Control.Monad.RWS.Strict hiding (local)
import           Data.Char (ord)
import           Data.DList (DList, fromList, toList, append)
import qualified Data.Text as T
import           System.FilePath (takeBaseName, takeExtension, replaceExtension)
import           System.Process (readProcess)

import           IRTS.CodegenCommon
import           IRTS.Lang
import           IRTS.Simplified
import           Idris.Core.CaseTree (CaseType(Shared))
import           Idris.Core.TT

import           Language.Cil
import qualified Language.Cil as Cil

import           IRTS.Cil.UnreachableCodeRemoval

codegenCil :: CodeGenerator
codegenCil ci = do writeFile cilFile $ pr (assemblyFor ci) ""
                   when (outputExtension /= ".il") $
                     ilasm cilFile output
  where cilFile = replaceExtension output "il"
        output  = outputFile ci
        outputExtension = takeExtension output

ilasm :: String -> String -> IO ()
ilasm input output = readProcess "ilasm" [input, "/output:" ++ output] "" >>= putStr

assemblyFor :: CodegenInfo -> Assembly
assemblyFor ci = Assembly [mscorlibRef] asmName [moduleFor ci, sconType, consType]
  where asmName  = quoted $ takeBaseName (outputFile ci)

moduleFor :: CodegenInfo -> TypeDef
moduleFor ci = classDef [CaPrivate] moduleName noExtends noImplements [] methods []
  where methods       = removeUnreachable $ map method declsWithBody
        declsWithBody = filter hasBody decls
        decls         = map snd $ simpleDecls ci
        hasBody (SFun _ _ _ sexp) = someSExp sexp
        someSExp :: SExp -> Bool
        someSExp SNothing              = False
        someSExp (SOp (LExternal _) _) = False
        someSExp _                     = True

moduleName :: String
moduleName = "'λΠ'"

method :: SDecl -> MethodDef
method decl@(SFun name ps _ sexp) = Method attrs retType (cilName name) parameters (toList body)
  where attrs      = [MaStatic, MaAssembly]
        retType    = Cil.Object
        parameters = map param ps
        param n    = Param Nothing Cil.Object (cilName n)
        body       = let (CodegenState _ lc, cilForSexp) = cilFor decl sexp
                     in fromList [entryPoint | isEntryPoint]
                       `append` locals lc
                       `append` cilForSexp
                       `append` [ret]
        locals lc  = fromList [localsInit $ map local [0..(lc - 1)] | lc > 0]
        local i    = Local Cil.Object ("l" ++ show i)
        isEntryPoint = name == entryPointName


data CodegenState = CodegenState { nextLabel  :: Int
                                 , localCount :: Int }

type CilCodegen a = RWS SDecl (DList MethodDecl) CodegenState a

cilFor :: SDecl -> SExp -> (CodegenState, DList MethodDecl)
cilFor decl sexp = execRWS (cil sexp) decl (CodegenState 0 0)

cil :: SExp -> CilCodegen ()
cil (SLet (Loc i) v e) = do
  case v of
    SNothing -> tell [ ldnull ]
    _        -> cil v
  li <- localIndex i
  storeLocal li
  cil e

cil (SUpdate (Loc i) v) = do
  cil v
  tell [ dup ]
  li <- localIndex i
  storeLocal li

cil (SV v) = load v
cil (SConst c) = cgConst c
cil SNothing = throwException "SNothing"
cil (SOp op args) = cgOp op args

-- Special constructors: True, False, List.Nil, List.::
cil (SCon _ 0 n []) | n == boolFalse = tell [ ldc_i4 0, box systemBoolean ]
cil (SCon _ 1 n []) | n == boolTrue  = tell [ ldc_i4 1, box systemBoolean ]
cil (SCon _ 0 n []) | n == listNil   = tell [ loadNil ]
cil (SCon _ 1 n [x, xs]) | n == listCons = do load x
                                              load xs
                                              tell [ castclass consTypeRef
                                                   , newobj "" "Cons" [Cil.Object, consTypeRef] ]
-- General constructors
cil (SCon Nothing t _ fs) = do
  tell [ ldc t
       , ldc $ length fs
       , newarr Cil.Object ]
  mapM_ storeElement (zip [0..] fs)
  tell [ newobj "" "SCon" [Int32, array] ]
  where storeElement (i, f) = do
          tell [ dup
               , ldc_i4 i ]
          load f
          tell [ stelem_ref ]

-- ifThenElse
cil (SCase Shared v [ SConCase _ 0 nFalse [] elseAlt
                    , SConCase _ 1 nTrue  [] thenAlt ]) | nFalse == boolFalse && nTrue == boolTrue =
  cgIfThenElse v thenAlt elseAlt $ \thenLabel ->
    tell [ unbox_any systemBoolean
         , brtrue thenLabel ]

cil (SCase Shared v [ SConCase _ c _ [] thenAlt, SDefaultCase elseAlt ]) =
  cgIfThenElse v thenAlt elseAlt $ \thenLabel -> do
    loadSConTag
    tell [ ldc c
         , beq thenLabel ]

cil (SCase Shared v [ SConstCase c thenAlt, SDefaultCase elseAlt ]) =
  cgIfThenElse v thenAlt elseAlt $ \thenLabel ->
    cgBranchEq c thenLabel

-- List case matching
cil (SCase Shared v [ SConCase _ 1 nCons [x, xs] consAlt
                    , SConCase _ 0 nNil  []      nilAlt ]) | nCons == listCons && nNil == listNil = do

  nilLabel <- newLabel "NIL"
  endLabel <- newLabel "END"

  load v
  tell [ loadNil
       , beq nilLabel ]
  load v
  tell [ castclass consTypeRef
       , dup
       , ldfld Cil.Object "" "Cons" "car" ]
  bind x
  tell [ ldfld consTypeRef "" "Cons" "cdr" ]
  bind xs
  cil consAlt
  tell [ br endLabel
       , label nilLabel ]
  cil nilAlt
  tell [ label endLabel ]
  where bind (MN i _) = storeLocal i

cil (SCase Shared v [c@SConCase{}]) = cgSConCase v c

-- cil (SCase Shared v alts) = cil (SChkCase v (sortedAlts ++ [SDefaultCase SNothing]))
--   where sortedAlts = sortBy (compare `on` tag) alts
--         tag (SConCase _ t _ _ _) = t
--         tag c                    = error $ show c

cil (SChkCase _ [SDefaultCase e]) = cil e
cil (SChkCase v alts) | canBuildJumpTable alts = do
  load v
  loadSConTag
  tell [ ldc baseTag
       , sub
       , switch labels ]
  mapM_ (cgAlt v) (zip labels alts)
  tell [ label "END" ]
  where canBuildJumpTable (SConCase _ t _ _ _ : xs) = canBuildJumpTable' t xs
        canBuildJumpTable _                         = False
        canBuildJumpTable' t (SConCase _ t' _ _ _ : xs) | t' == t + 1 = canBuildJumpTable' t' xs
        canBuildJumpTable' _ [SDefaultCase _]                         = True
        canBuildJumpTable' _ _                                        = False
        baseTag = let (SConCase _ t _ _ _) = head alts in t
        labels = map (("L"++) . show) [0..(length alts - 1)]

cil (SApp isTailCall n args) = do
  mapM_ load args
  if isTailCall
    then tell [ tailcall app, ret, ldnull ]
    else tell [ app ]
  where app = call [] Cil.Object "" moduleName (cilName n) (map (const Cil.Object) args)

cil e = unsupported "expression" e

loadSConTag :: CilCodegen ()
loadSConTag = tell [ castclass (ReferenceType "" "SCon")
                   , ldfld Int32 "" "SCon" "tag" ]

cgIfThenElse :: LVar -> SExp -> SExp -> (String -> CilCodegen ()) -> CilCodegen ()
cgIfThenElse v thenAlt elseAlt cgBranch = do
  thenLabel <- newLabel "THEN"
  endLabel  <- newLabel "END"
  load v
  cgBranch thenLabel
  cil elseAlt
  tell [ br endLabel
       , label thenLabel ]
  cil thenAlt
  tell [ label endLabel ]

cgConst :: Const -> CilCodegen ()
cgConst (Str s) = tell [ ldstr s ]
cgConst (I i)   = cgConst . BI . fromIntegral $ i
cgConst (BI i)  = tell [ ldc i
                       , boxInt32 ]
cgConst (Ch c)  = tell [ ldc $ ord c
                       , box systemChar ]
cgConst c = unsupported "const" c
{-
  = I Int
  | BI Integer
  | Fl Double
  | Ch Char
  | Str String
  | B8 GHC.Word.Word8
  | B16 GHC.Word.Word16
  | B32 GHC.Word.Word32
  | B64 GHC.Word.Word64
  | AType ArithTy
  | StrType
  | WorldType
  | TheWorld
  | VoidType
  | Forgot
-}

storeLocal :: Int -> CilCodegen ()
storeLocal i = do
  tell [ stloc i ]
  modify ensureLocal
  where ensureLocal CodegenState{..} = CodegenState nextLabel (max localCount (i + 1))

cgBranchEq :: Const -> String -> CilCodegen ()
cgBranchEq (Ch c) target =
  tell [ unbox_any systemChar
       , ldc $ ord c
       , beq target ]
cgBranchEq (BI i) target = cgBranchEq (I . fromIntegral $ i) target
cgBranchEq (I i) target =
  tell [ unbox_any Int32
       , ldc i
       , beq target ]
cgBranchEq c _ = unsupported "branch on const" c

cgSConCase :: LVar -> SAlt -> CilCodegen ()
cgSConCase v (SConCase _ _ _ fs sexp) = do
  unless (null fs) $ do
    load v
    tell [ castclass sconTypeRef
         , ldfld array "" "SCon" "fields" ]
    mapM_ loadElement (zip [0..] fs)
    tell [ pop ]
  cil sexp
  where loadElement :: (Int, Name) -> CilCodegen ()
        loadElement (e, MN i _) = do
          tell [ dup
               , ldc e
               , ldelem_ref ]
          storeLocal i

cgAlt :: LVar -> (Label, SAlt) -> CilCodegen ()
cgAlt v (l, c@(SConCase{})) = do
  tell [ label l ]
  cgSConCase v c
  tell [ br "END" ]

cgAlt _ (l, SDefaultCase v) = do
  tell [ label l ]
  cil v
  tell [ br "END" ]

cgAlt _ (l, e) = do
  tell [ label l ]
  unsupported "case" e
  tell [ br "END" ]

cgOp :: PrimFn -> [LVar] -> CilCodegen ()
cgOp LWriteStr [_, s] = do
  load s
  tell [ castclass String
       , call [] Void "mscorlib" "System.Console" "Write" [String]
       , ldnull ]

cgOp LStrConcat args = do
  forM_ args loadString
  tell [ call [] String "mscorlib" "System.String" "Concat" (map (const String) args) ]

cgOp LStrCons [h, t] = do
  loadAs systemChar h
  tell [ call [] String "mscorlib" "System.Char" "ToString" [Char] ]
  loadString t
  tell [ call [] String "mscorlib" "System.String" "Concat" [String, String] ]

cgOp LStrEq args = do
  forM_ args loadString
  tell [ call [] Bool "mscorlib" "System.String" "op_Equality" (map (const String) args)
       , box systemInt32 ] -- strange but correct

-- cgOp LStrHead [v] = do
--   loadString v
--   tell [ ldc_i4 0
--        , call [CcInstance] Char "mscorlib" "System.String" "get_Chars" [Int32]
--        , box systemChar ]

-- cgOp LStrTail [v] = do
--   loadString v
--   tell [ ldc_i4 1
--        , call [CcInstance] String "mscorlib" "System.String" "Substring" [Int32] ]

-- cgOp (LChInt ITNative) [c] = do
--   load c
--   tell [ unbox_any systemChar
--        , box systemInt32 ]

-- cgOp (LEq (ATInt ITChar)) args = do
--   forM_ args loadChar
--   tell [ ceq
--        , box systemBoolean ]

-- cgOp (LSLt (ATInt ITChar)) args = do
--   forM_ args loadChar
--   tell [ clt
--        , box systemBoolean ]

cgOp (LSExt ITNative ITBig) [i]  = load i
cgOp (LPlus (ATInt _))      args = intOp add args
cgOp (LMinus (ATInt _))     args = intOp sub args
cgOp (LEq (ATInt _))        args = intOp ceq args
cgOp (LSLt (ATInt _))       args = intOp clt args
cgOp (LIntStr _)            [i]  = do
  load i
  tell [ callvirt String "mscorlib" "System.Object" "ToString" [] ]
cgOp o _ = unsupported "operation" o

unsupported :: Show a => String -> a -> CilCodegen ()
unsupported desc v = do
  decl <- ask
  throwException $ "Unsupported " ++ desc ++ " `" ++ show v ++ "' in\n" ++ show decl

throwException :: String -> CilCodegen ()
throwException message =
  tell [ ldstr message
       , newobj "mscorlib" "System.Exception" [String]
       , throw ]

newLabel :: String -> CilCodegen String
newLabel prefix = do
  (CodegenState suffix locals) <- get
  put (CodegenState (suffix + 1) locals)
  return $ prefix ++ show suffix

intOp :: MethodDecl -> [LVar] -> CilCodegen ()
intOp op args = do
  forM_ args loadInt32
  tell [ op
       , boxInt32 ]

boxInt32 :: MethodDecl
boxInt32 = box systemInt32

loadInt32, loadChar :: LVar -> CilCodegen ()
loadInt32 = loadAs systemInt32
loadChar  = loadAs systemChar

loadAs :: PrimitiveType -> LVar -> CilCodegen ()
loadAs valueType l = do
  load l
  tell [ unbox_any valueType ]

loadString :: LVar -> CilCodegen ()
loadString l = do
  load l
  tell [ castclass String ]

loadNil :: MethodDecl
loadNil = ldsfld consTypeRef "" "Cons" "Nil"

ldc :: (Integral n) => n -> MethodDecl
ldc = ldc_i4 . fromIntegral

load :: LVar -> CilCodegen ()
load (Loc i) = do
  li <- localIndex i
  tell [
    if li < 0
      then ldarg i
      else ldloc li ]

localIndex :: Offset -> CilCodegen Offset
localIndex i = do
  (SFun _ ps _ _) <- ask
  return $ i - length ps

entryPointName :: Name
entryPointName = MN 0 "runMain"
--entryPointName = NS (UN "main") ["Main"]

cilName :: Name -> String
cilName = quoted . T.unpack . showName
  where showName (NS n ns) = T.intercalate "." . reverse $ showName n : ns
        showName (UN t)    = t
        showName (MN i t)  = T.concat [t, T.pack $ show i]
        showName (SN sn)   = T.pack $ show sn
        showName e = error $ "Unsupported name `" ++ show e ++ "'"

consType :: TypeDef
consType = classDef [CaPrivate] className noExtends noImplements
                    [car, cdr, nil] [ctor, cctor] []
  where className = "Cons"
        nil       = Field [FaStatic, FaPublic] consTypeRef "Nil"
        cctor     = Constructor [MaStatic] Void []
                      [ ldnull
                      , ldnull
                      , newobj "" className [Cil.Object, consTypeRef]
                      , stsfld consTypeRef "" className "Nil"
                      , ret ]
        car       = Field [FaPublic] Cil.Object "car"
        cdr       = Field [FaPublic] consTypeRef "cdr"
        ctor      = Constructor [MaPublic] Void [ Param Nothing Cil.Object "car"
                                                , Param Nothing consTypeRef "cdr" ]
                      [ ldarg 0
                      , call [CcInstance] Void "" "object" ".ctor" []
                      , ldarg 0
                      , ldarg 1
                      , stfld Cil.Object "" className "car"
                      , ldarg 0
                      , ldarg 2
                      , stfld consTypeRef "" className "cdr"
                      , ret ]

sconType :: TypeDef
sconType = classDef [CaPrivate] className noExtends noImplements
                    [sconTag, sconFields] [sconCtor] []
  where className  = "SCon"
        sconTag    = Field [FaPublic] Int32 "tag"
        sconFields = Field [FaPublic] array "fields"
        sconCtor   = Constructor [MaPublic] Void [ Param Nothing Int32 "tag"
                                                 , Param Nothing array "fields" ]
                     [ ldarg 0
                     , call [CcInstance] Void "" "object" ".ctor" []
                     , ldarg 0
                     , ldarg 1
                     , stfld Int32 "" className "tag"
                     , ldarg 0
                     , ldarg 2
                     , stfld array "" className "fields"
                     , ret ]

consTypeRef, sconTypeRef :: PrimitiveType
consTypeRef = ReferenceType "" "Cons"
sconTypeRef = ReferenceType "" "SCon"

systemBoolean, systemChar, systemInt32, array :: PrimitiveType
systemBoolean = ValueType "mscorlib" "System.Boolean"
systemChar    = ValueType "mscorlib" "System.Char"
systemInt32   = ValueType "mscorlib" "System.Int32"
array          = Array Cil.Object

boolFalse, boolTrue, listNil, listCons :: Name
boolFalse = NS (UN "False") ["Bool", "Prelude"]
boolTrue  = NS (UN "True")  ["Bool", "Prelude"]
listNil   = NS (UN "Nil")   ["List", "Prelude"]
listCons  = NS (UN "::")    ["List", "Prelude"]

quoted :: String -> String
quoted n = "'" ++ concatMap validChar n ++ "'"
  where validChar c = if c == '\''
                         then "\\'"
                         else [c]

consoleWriteLine :: String -> DList MethodDecl
consoleWriteLine s = [ ldstr s
                     , call [] Void "mscorlib" "System.Console" "WriteLine" [String] ]
