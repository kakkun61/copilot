{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Copilot.Compile.C.CodeGen where

import Text.PrettyPrint     (render)
import Control.Monad.State  (runState)
import Data.List            (union, nub)
import Data.Maybe           (catMaybes)
import Data.Typeable        (Typeable)

import Language.C99.Pretty  (pretty)
import qualified Language.C99.Simple as C

import Copilot.Core
import Copilot.Compile.C.Util
import Copilot.Compile.C.External
import Copilot.Compile.C.Translate

-- | Compile the specification to a .h and a .c file.
compile :: Spec -> String -> IO ()
compile spec prefix = do
  let cfile = render $ pretty $ C.translate $ compilec spec
      hfile = render $ pretty $ C.translate $ compileh spec

      -- TODO: find a nicer solution using annotated AST's
      cmacros = unlines [ "#include <stdint.h>"
                        , "#include <stdbool.h>"
                        , "#include <string.h>"
                        , ""
                        , "#include \"" ++ prefix ++ ".h\""
                        , ""
                        ]

  writeFile (prefix ++ ".c") $ cmacros ++ cfile
  writeFile (prefix ++ ".h") hfile

-- | Generate the .c file from a spec. It has the following structure:
-- |
-- | * Include .h file
-- | * Declarations of global buffers and indices.
-- | * Generator functions for streams, guards and trigger args.
-- | * Declaration of step() function.
compilec :: Spec -> C.TransUnit
compilec spec = C.TransUnit declns funs where
  streams  = specStreams spec
  triggers = specTriggers spec
  exts     = gatherexts streams triggers

  declns = mkexts exts ++ mkglobals streams
  funs   = genfuns streams triggers ++ [mkstep streams triggers exts]

  -- Make declarations for copies of external variables.
  mkexts :: [External] -> [C.Decln]
  mkexts exts = map mkextcpydecln exts

  -- Make buffer and index declarations for streams.
  mkglobals :: [Stream] -> [C.Decln]
  mkglobals streams = map buffdecln streams ++ map indexdecln streams where
    buffdecln  (Stream sid buff _ ty) = mkbuffdecln  sid ty buff
    indexdecln (Stream sid _    _ _ ) = mkindexdecln sid

  -- Make generator functions, including trigger arguments.
  genfuns :: [Stream] -> [Trigger] -> [C.FunDef]
  genfuns streams triggers =  map streamgen streams
                           ++ concatMap triggergen triggers where
    streamgen :: Stream -> C.FunDef
    streamgen (Stream sid _ expr ty) = genfun (generatorname sid) expr ty

    triggergen :: Trigger -> [C.FunDef]
    triggergen (Trigger name guard args) = guarddef : argdefs where
      guarddef = genfun (guardname name) guard Bool
      argdefs  = map arggen (zip (argnames name) args)

      arggen :: (String, UExpr) -> C.FunDef
      arggen (argname, UExpr ty expr) = genfun argname expr ty

-- | Generate the .h file from a spec.
compileh :: Spec -> C.TransUnit
compileh spec = C.TransUnit declns [] where
  streams  = specStreams spec
  triggers = specTriggers spec
  exts     = gatherexts streams triggers
  exprs    = gatherexprs streams triggers

  declns =  mkstructdeclns exprs
         ++ mkexts exts
         ++ extfundeclns triggers
         ++ [stepdecln]

  -- Write struct datatypes
  mkstructdeclns :: [UExpr] -> [C.Decln]
  mkstructdeclns es = catMaybes $ map mkdecln utypes where
    mkdecln (UType ty) = case ty of
      Struct x -> Just $ mkstructdecln ty
      _        -> Nothing

    utypes = nub $ concatMap (\(UExpr _ e) -> exprtypes e) es

  -- Make declarations for external variables.
  mkexts :: [External] -> [C.Decln]
  mkexts = map mkextdecln

  extfundeclns :: [Trigger] -> [C.Decln]
  extfundeclns triggers = map extfundecln triggers where
    extfundecln :: Trigger -> C.Decln
    extfundecln (Trigger name _ args) = C.FunDecln Nothing cty name params where
        cty    = C.TypeSpec C.Void
        params = map mkparam $ zip (argnames name) args
        mkparam (name, UExpr ty _) = C.Param (transtype ty) name

  -- Declaration for the step function.
  stepdecln :: C.Decln
  stepdecln = C.FunDecln Nothing (C.TypeSpec C.Void) "step" []



-- | Write a declaration for a generator function.
gendecln :: String -> Type a -> C.Decln
gendecln name ty = C.FunDecln Nothing cty name [] where
  cty = C.decay $ transtype ty

-- | Write a generator function for a stream.
genfun :: String -> Expr a -> Type a -> C.FunDef
genfun name expr ty = C.FunDef cty name [] cvars [C.Return $ Just cexpr] where
  cty = C.decay $ transtype ty
  (cexpr, (cvars, _)) = runState (transexpr expr) mempty

-- | Make a extern declaration of an variable.
mkextdecln :: External -> C.Decln
mkextdecln (External name _ ty) = decln where
  decln = C.VarDecln (Just C.Extern) cty name Nothing
  cty   = transtype ty

-- | Make a declaration for a copy of an external variable.
mkextcpydecln :: External -> C.Decln
mkextcpydecln (External name cpyname ty) = decln where
  cty   = transtype ty
  decln = C.VarDecln (Just C.Static) cty cpyname Nothing

-- | Make a C buffer variable and initialise it with the stream buffer.
mkbuffdecln :: Id -> Type a -> [a] -> C.Decln
mkbuffdecln sid ty xs = C.VarDecln (Just C.Static) cty name initvals where
  name     = streamname sid
  cty      = C.Array (transtype ty) (Just $ C.LitInt $ fromIntegral buffsize)
  buffsize = length xs
  initvals = Just $ C.InitArray $ map (mkinit ty) xs

-- | Make a C index variable and initialise it to 0.
mkindexdecln :: Id -> C.Decln
mkindexdecln sid = C.VarDecln (Just C.Static) cty name initval where
  name    = indexname sid
  cty     = C.TypeSpec $ C.TypedefName "size_t"
  initval = Just $ C.InitExpr $ C.LitInt 0

-- | Make an initial declaration from a single value.
mkinit :: Type a -> a -> C.Init
mkinit (Array ty') xs = C.InitArray $ map (mkinit ty') (arrayelems xs)
mkinit (Struct _)  x  = C.InitArray $ map fieldinit (toValues x) where
  fieldinit (Value ty (Field val)) = mkinit ty val
mkinit ty          x  = C.InitExpr  $ constty ty x

-- | The step function updates all streams,a
mkstep :: [Stream] -> [Trigger] -> [External] -> C.FunDef
mkstep streams triggers exts = C.FunDef void "step" [] declns stmts where
  void = C.TypeSpec C.Void
  declns = []
  stmts  =  map mkexcopy exts
         ++ map mktriggercheck triggers
         ++ map mkupdatebuffer streams
         ++ map mkupdateindex streams

  -- Make code that copies an external variable to its local one.
  mkexcopy :: External -> C.Stmt
  mkexcopy (External name cpyname ty) = C.Expr $ case ty of
    Array _ -> memcpy exvar locvar size where
                 exvar  = C.Ident cpyname
                 locvar = C.Ident name
                 size   = C.LitInt $ fromIntegral $ tysize ty
    _       -> C.Ident cpyname C..= C.Ident name

  -- Make if-statement to check the guard, call the trigger if necessary.
  mktriggercheck :: Trigger -> C.Stmt
  mktriggercheck (Trigger name guard args) = C.If guard' firetrigger where
    guard'      = C.Funcall (C.Ident $ guardname name) []
    firetrigger = [C.Expr $ C.Funcall (C.Ident name) args'] where
      args'        = take (length args) (map argcall (argnames name))
      argcall name = C.Funcall (C.Ident name) []

  -- Code to update the global buffer.
  mkupdatebuffer :: Stream -> C.Stmt
  mkupdatebuffer (Stream sid buff expr ty) = case ty of
    Array _ -> C.Expr $ memcpy dest src size where
      dest = C.Index (C.Ident $ streamname sid) (C.Ident $ indexname sid)
      src  = C.Funcall (C.Ident $ generatorname sid) []
      size = C.LitInt $ fromIntegral $ tysize ty
    _ -> C.Expr $ C.Index var index C..= val where
      var   = C.Ident $ streamname sid
      index = C.Ident $ indexname sid
      val   = C.Funcall (C.Ident $ generatorname sid) []

  -- Code to update the index.
  mkupdateindex :: Stream -> C.Stmt
  mkupdateindex (Stream sid buff expr ty) = C.Expr $ globvar C..= val where
    globvar = C.Ident $ indexname sid
    index   = (C..++) (C.Ident $ indexname sid)
    val     = index C..% (C.LitInt $ fromIntegral len)
    len     = length buff

  -- Write a call to the memcpy function.
  memcpy :: C.Expr -> C.Expr -> C.Expr -> C.Expr
  memcpy dest src size = C.Funcall (C.Ident "memcpy") [dest, src, size]


-- | Write a struct declaration based on its definition.
mkstructdecln :: Struct a => Type a -> C.Decln
mkstructdecln (Struct x) = C.TypeDecln struct where
  struct = C.TypeSpec $ C.StructDecln (Just $ typename x) fields
  fields = map mkfield (toValues x)

  mkfield :: Value a -> C.FieldDecln
  mkfield (Value ty field) = C.FieldDecln (transtype ty) (fieldname field)

-- | List all types of an expression, returns items uniquely.
exprtypes :: Typeable a => Expr a -> [UType]
exprtypes e = case e of
  Const ty _            -> typetypes ty
  Local ty1 ty2 _ e1 e2 -> typetypes ty1 `union` typetypes ty2
                           `union` exprtypes e1 `union` exprtypes e2
  Var ty _              -> typetypes ty
  Drop ty _ _           -> typetypes ty
  ExternVar ty _ _      -> typetypes ty
  Op1 _ e1              -> exprtypes e1
  Op2 _ e1 e2           -> exprtypes e1 `union` exprtypes e2
  Op3 _ e1 e2 e3        -> exprtypes e1 `union` exprtypes e2 `union` exprtypes e3

-- | List all types of an type, returns items uniquely.
typetypes :: Typeable a => Type a -> [UType]
typetypes ty = case ty of
  Array ty' -> [UType ty] `union` typetypes ty
  Struct x  -> [UType ty] `union` map (\(Value ty' _) -> UType ty') (toValues x)
  _         -> [UType ty]

-- | Collect all expression of a list of streams and triggers and wrap them
-- into an UEXpr.
gatherexprs :: [Stream] -> [Trigger] -> [UExpr]
gatherexprs streams triggers =  map streamexpr streams
                             ++ concatMap triggerexpr triggers where
  streamexpr  (Stream _ _ expr ty)   = UExpr ty expr
  triggerexpr (Trigger _ guard args) = UExpr Bool guard : args

