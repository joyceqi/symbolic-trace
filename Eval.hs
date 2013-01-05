-- Symbolic evaluator for basic blocks

module Main where

import Data.LLVM.Types
import LLVM.Parse
import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Bits as Bits
import Data.Word
import Control.Applicative
import Data.Maybe
import Debug.Trace
import Data.Binary.Get(Get, runGet, getWord32host, getWord64host, skip)
import qualified Data.ByteString.Lazy as B
import Control.Monad
import Control.Monad.Trans.State.Lazy
import Control.Monad.Trans.Class(lift, MonadTrans)
import Control.Monad.Trans.Maybe
import Text.Printf(printf)

type UInt = Word64

data Loc = IdLoc Function Identifier | MemLoc AddrEntry
    deriving (Eq, Ord)

instance Show Loc where
    show (IdLoc f id) = printf "IdLoc %s %s" (show $ functionName f) (show id)
    show (MemLoc addr) = printf "MemLoc (%s)" (show addr)

class Pretty a where
    pretty :: a -> String

instance Pretty AddrEntry where
    pretty AddrEntry{ addrType = MAddr, addrVal = val }
        = printf "0x%08x" val
    pretty AddrEntry{ addrType = GReg, addrVal = reg } = case reg of
        0 -> "EAX"
        1 -> "ECX"
        2 -> "EDX"
        3 -> "EBX"
        4 -> "ESP"
        5 -> "EBP"
        6 -> "ESI"
        7 -> "EDI"
        _ -> "Reg" ++ show reg
    pretty addr = show addr

instance Pretty Loc where
    pretty (IdLoc f id) = printf "%s: %s" (show $ functionName f) (show id)
    pretty (MemLoc addr) = pretty addr

data ExprT = VoidT | PtrT | Int8T | Int32T | Int64T | FloatT | DoubleT
    deriving (Eq, Ord, Show)
data Expr =
    AddExpr ExprT Expr Expr |
    SubExpr ExprT Expr Expr |
    MulExpr ExprT Expr Expr |
    DivExpr ExprT Expr Expr |
    RemExpr ExprT Expr Expr |
    ShlExpr ExprT Expr Expr |
    LshrExpr ExprT Expr Expr |
    AshrExpr ExprT Expr Expr |
    AndExpr ExprT Expr Expr |
    OrExpr ExprT Expr Expr |
    XorExpr ExprT Expr Expr |
    TruncExpr ExprT Expr |
    ZExtExpr ExprT Expr |
    SExtExpr ExprT Expr |
    FPTruncExpr ExprT Expr |
    FPExtExpr ExprT Expr |
    FPToSIExpr ExprT Expr |
    FPToUIExpr ExprT Expr |
    SIToFPExpr ExprT Expr |
    UIToFPExpr ExprT Expr |
    PtrToIntExpr ExprT Expr |
    IntToPtrExpr ExprT Expr |
    BitcastExpr ExprT Expr |
    LoadExpr ExprT AddrEntry |
    BinaryHelperExpr ExprT Identifier Expr Expr | -- not witnessed
    CastHelperExpr ExprT Identifier Expr |
    ILitExpr Integer | -- takes any integer type
    FLitExpr Double | -- takes any float type
    InputExpr ExprT Loc |
    IrrelevantExpr
    deriving (Eq, Ord)

instance Show Expr where
    show (AddExpr _ e1 e2) = printf "(%s + %s)" (show e1) (show e2)
    show (SubExpr _ e1 e2) = printf "(%s - %s)" (show e1) (show e2)
    show (MulExpr _ e1 e2) = printf "(%s * %s)" (show e1) (show e2)
    show (DivExpr _ e1 e2) = printf "(%s / %s)" (show e1) (show e2)
    show (RemExpr _ e1 e2) = printf "(%s % %s)" (show e1) (show e2)
    show (ShlExpr _ e1 e2) = printf "(%s << %s)" (show e1) (show e2)
    show (LshrExpr _ e1 e2) = printf "(%s L>> %s)" (show e1) (show e2)
    show (AshrExpr _ e1 e2) = printf "(%s A>> %s)" (show e1) (show e2)
    show (AndExpr _ e1 e2) = printf "(%s & %s)" (show e1) (show e2)
    show (OrExpr _ e1 e2) = printf "(%s | %s)" (show e1) (show e2)
    show (XorExpr _ e1 e2) = printf "(%s ^ %s)" (show e1) (show e2)
    show (TruncExpr _ e) = printf "%s" (show e)
    show (ZExtExpr _ e) = printf "%s" (show e)
    show (SExtExpr _ e) = printf "%s" (show e)
    show (FPTruncExpr _ e) = printf "FPTrunc(%s)" (show e)
    show (FPExtExpr _ e) = printf "FPExt(%s)" (show e)
    show (FPToSIExpr _ e) = printf "FPToSI(%s)" (show e)
    show (FPToUIExpr _ e) = printf "FPToUI(%s)" (show e)
    show (SIToFPExpr _ e) = printf "SIToFP(%s)" (show e)
    show (UIToFPExpr _ e) = printf "UIToFP(%s)" (show e)
    show (PtrToIntExpr _ e) = printf "PtrToInt(%s)" (show e)
    show (IntToPtrExpr _ e) = printf "IntToPtr(%s)" (show e)
    show (BitcastExpr _ e) = printf "Bitcast(%s)" (show e)
    show (LoadExpr _ addr) = printf "*%s" (pretty addr)
    show (BinaryHelperExpr _ id e1 e2) = printf "%s(%s, %s)" (show id) (show e1) (show e2)
    show (CastHelperExpr _ id e) = printf "%s(%s)" (show id) (show e)
    show (ILitExpr i) = show i
    show (FLitExpr f) = show f
    show (InputExpr _ loc) = printf "(%s)" (show loc)
    show (IrrelevantExpr) = "IRRELEVANT"

bits :: ExprT -> Int
bits Int8T = 8
bits Int32T = 32
bits Int64T = 64
bits t = error $ "Unexpected argument to bits: " ++ show t

simplify :: Expr -> Expr
simplify (AddExpr t e1 (ILitExpr 0)) = simplify e1
simplify (AddExpr t (ILitExpr 0) e2) = simplify e2
simplify (AddExpr t e1 e2) = AddExpr t (simplify e1) (simplify e2)
simplify (SubExpr t e1 e2) = SubExpr t (simplify e1) (simplify e2)
simplify (MulExpr t e1 e2) = MulExpr t (simplify e1) (simplify e2)
simplify (DivExpr t e1 e2) = DivExpr t (simplify e1) (simplify e2)
simplify (RemExpr t e1 e2) = RemExpr t (simplify e1) (simplify e2)
simplify (ShlExpr t e1 e2) = ShlExpr t (simplify e1) (simplify e2)
simplify (LshrExpr t e1 e2) = LshrExpr t (simplify e1) (simplify e2)
simplify (AshrExpr _ (ILitExpr 0) _) = ILitExpr 0
simplify (AshrExpr t e1 e2) = AshrExpr t (simplify e1) (simplify e2)
simplify (AndExpr t e1 e2) = AndExpr t (simplify e1) (simplify e2)
simplify (OrExpr t e1 e2) = OrExpr t (simplify e1) (simplify e2)
simplify (XorExpr t e1 e2) = XorExpr t (simplify e1) (simplify e2)
simplify (TruncExpr _ (ZExtExpr _ e)) = simplify e
simplify (TruncExpr _ (SExtExpr _ e)) = simplify e
simplify expr@(TruncExpr t e@(ILitExpr int))
    | int < 2 ^ bits t = e
    | otherwise = expr
simplify (TruncExpr t e) = TruncExpr t (simplify e)
simplify (ZExtExpr t e@ILitExpr{}) = e
simplify (ZExtExpr t e) = ZExtExpr t (simplify e)
simplify (SExtExpr t e@ILitExpr{}) = e -- FIXME: add typing to lits
simplify (SExtExpr t e) = SExtExpr t (simplify e)
simplify (FPTruncExpr t e) = FPTruncExpr t (simplify e)
simplify (FPExtExpr t e) = FPExtExpr t (simplify e)
simplify (FPToSIExpr t e) = FPToSIExpr t (simplify e)
simplify (FPToUIExpr t e) = FPToUIExpr t (simplify e)
simplify (SIToFPExpr t e) = SIToFPExpr t (simplify e)
simplify (UIToFPExpr t e) = UIToFPExpr t (simplify e)
simplify (PtrToIntExpr t1 (IntToPtrExpr t2 e)) = simplify e
simplify (IntToPtrExpr t1 (PtrToIntExpr Int64T e)) = simplify e
simplify (PtrToIntExpr t e) = PtrToIntExpr t (simplify e)
simplify (IntToPtrExpr t e) = IntToPtrExpr t (simplify e)
simplify (BitcastExpr t e) = BitcastExpr t (simplify e)
-- simplify (LoadExpr t e) = LoadExpr t (simplify e)
simplify (BinaryHelperExpr t id e1 e2) = BinaryHelperExpr t id (simplify e1) (simplify e2)
simplify (CastHelperExpr t id e) = CastHelperExpr t id (simplify e)
simplify e = e

-- Simple type system
typeToExprT :: Type -> ExprT
typeToExprT (TypeInteger 8) = Int8T
typeToExprT (TypeInteger 32) = Int32T
typeToExprT (TypeInteger 64) = Int32T
typeToExprT (TypePointer _ _) = PtrT
typeToExprT (TypeFloat) = FloatT
typeToExprT (TypeDouble) = DoubleT
typeToExprT _ = VoidT

exprTOfInst :: Instruction -> ExprT
exprTOfInst = typeToExprT . instructionType

data LocInfo = LocInfo{
    locExpr :: Expr,
    locRelevant :: Bool
} deriving (Eq, Ord, Show)

-- Representation of our [partial] knowledge of machine state.
type Info = M.Map Loc LocInfo
data SymbolicState = SymbolicState {
        symbolicInfo :: Info,
        symbolicNextBlock :: Maybe BasicBlock,
        symbolicFunction :: Function
    } deriving (Eq, Ord, Show)
type Symbolic = State SymbolicState

getInfo :: Symbolic Info
getInfo = symbolicInfo <$> get
getNextBlock :: Symbolic (Maybe BasicBlock)
getNextBlock = symbolicNextBlock <$> get
getCurrentFunction :: Symbolic Function
getCurrentFunction = symbolicFunction <$> get
putInfo :: Info -> Symbolic ()
putInfo info = modify (\s -> s{ symbolicInfo = info })
putNextBlock :: Maybe BasicBlock -> Symbolic ()
putNextBlock maybeBlock = modify (\s -> s{ symbolicNextBlock = maybeBlock })

infoInsert :: Loc -> Expr -> Symbolic ()
infoInsert key expr = do
    info <- getInfo
    putInfo $ M.insert key locInfo info
    where locInfo = LocInfo{ locExpr = expr, locRelevant = False }
makeRelevant :: Loc -> Symbolic ()
makeRelevant loc = do
    info <- getInfo
    putInfo $ M.adjust (\li -> li{ locRelevant = True }) loc info
exprFindInfo :: Expr -> Loc -> Symbolic Expr
exprFindInfo def key = locExpr <$> M.findWithDefault defLocInfo key <$> getInfo
    where defLocInfo = LocInfo { locExpr = def, locRelevant = undefined }
isRelevant :: Loc -> Symbolic Bool
isRelevant loc = do
    info <- getInfo
    case M.lookup loc info of
        Nothing -> return False
        Just locInfo -> return $ locRelevant locInfo

noSymbolicState :: SymbolicState
noSymbolicState = SymbolicState{ symbolicInfo = M.empty,
                                 symbolicNextBlock = Nothing,
                                 symbolicFunction = error "No function." }

valueAt :: Loc -> Symbolic Expr
valueAt loc = exprFindInfo (InputExpr Int64T loc) loc

data BuildExprM a
    = Irrelevant
    | ErrorI String
    | JustI a

newtype BuildExprT m a = BuildExprT { runBuildExprT :: m (BuildExprM a) }

type BuildExpr a = BuildExprT (Symbolic) a

instance (Monad m) => Monad (BuildExprT m) where
    x >>= f = BuildExprT $ do
        v <- runBuildExprT x
        case v of
            JustI y -> runBuildExprT (f y)
            Irrelevant -> return Irrelevant
            ErrorI s -> return $ ErrorI s
    return x = BuildExprT (return $ JustI x)
    fail e = BuildExprT (return $ ErrorI e)

instance MonadTrans BuildExprT where
    lift m = BuildExprT $ do
        x <- m
        return $ JustI x

irrelevant :: (Monad m) => BuildExprT m a
irrelevant = BuildExprT $ return Irrelevant

instance (Monad m) => Functor (BuildExprT m) where
    fmap f x = x >>= return . f

instance (Monad m) => Applicative (BuildExprT m) where
    pure = return
    (<*>) = ap

instance (Monad m) => Alternative (BuildExprT m) where
    empty = BuildExprT $ return $ ErrorI ""
    mx <|> my = BuildExprT $ do
        x <- runBuildExprT mx
        y <- runBuildExprT my
        case (x, y) of
            (JustI z, _) -> return $ JustI z
            (Irrelevant, _) -> return Irrelevant
            (ErrorI _, JustI z) -> return $ JustI z
            (ErrorI _, Irrelevant) -> return Irrelevant
            (ErrorI s, ErrorI _) -> return $ ErrorI s

buildExprToMaybeExpr :: (Functor m, Monad m) => BuildExprT m Expr -> MaybeT m Expr
buildExprToMaybeExpr = MaybeT . fmap buildExprMToMaybeExpr . runBuildExprT

buildExprMToMaybeExpr :: BuildExprM Expr -> Maybe Expr
buildExprMToMaybeExpr (JustI e) = Just e
buildExprMToMaybeExpr (ErrorI s) = Nothing
buildExprMToMaybeExpr Irrelevant = Just IrrelevantExpr

maybeToM :: (Monad m) => Maybe a -> m a
maybeToM (Just x) = return x
maybeToM (Nothing) = fail ""

instructionToExpr :: Instruction -> BuildExpr Expr
instructionToExpr inst = do
    name <- case instructionName inst of
        Just n -> return n
        Nothing -> fail "No name for inst"
    func <- lift getCurrentFunction
    value <- lift $ valueAt (IdLoc func name)
    case value of
        IrrelevantExpr -> irrelevant
        e -> return e

valueContentToExpr :: ValueContent -> BuildExpr Expr
valueContentToExpr (ConstantC (ConstantFP _ _ value)) = return $ FLitExpr value 
valueContentToExpr (ConstantC (ConstantInt _ _ value)) = return $ ILitExpr value
valueContentToExpr (ConstantC (ConstantValue{ constantInstruction = inst })) = instructionToExpr inst
valueContentToExpr (InstructionC inst) = instructionToExpr inst
valueContentToExpr (ArgumentC (Argument{ argumentName = name,
                                         argumentType = argType })) = do
    func <- lift getCurrentFunction
    return $ InputExpr (typeToExprT argType) (IdLoc func name)
valueContentToExpr val = trace ("Couldn't find expr for " ++ show val) fail ""

valueToExpr :: Value -> BuildExpr Expr
valueToExpr = valueContentToExpr . valueContent

binaryInstToExprConstructor :: Instruction -> BuildExpr (ExprT -> Expr -> Expr -> Expr)
binaryInstToExprConstructor AddInst{} = return AddExpr
binaryInstToExprConstructor SubInst{} = return SubExpr
binaryInstToExprConstructor MulInst{} = return MulExpr
binaryInstToExprConstructor DivInst{} = return DivExpr
binaryInstToExprConstructor RemInst{} = return RemExpr
binaryInstToExprConstructor ShlInst{} = return ShlExpr
binaryInstToExprConstructor LshrInst{} = return LshrExpr
binaryInstToExprConstructor AshrInst{} = return AshrExpr
binaryInstToExprConstructor AndInst{} = return AndExpr
binaryInstToExprConstructor OrInst{} = return OrExpr
binaryInstToExprConstructor XorInst{} = return XorExpr
binaryInstToExprConstructor _ = fail ""

binaryInstToExpr :: Instruction -> BuildExpr Expr
binaryInstToExpr inst = do
    exprConstructor <- binaryInstToExprConstructor inst
    lhs <- valueToExpr $ binaryLhs inst
    rhs <- valueToExpr $ binaryRhs inst
    return $ exprConstructor (exprTOfInst inst) lhs rhs

castInstToExprConstructor :: Instruction -> BuildExpr (ExprT -> Expr -> Expr)
castInstToExprConstructor TruncInst{} = return TruncExpr
castInstToExprConstructor ZExtInst{} = return ZExtExpr
castInstToExprConstructor SExtInst{} = return SExtExpr
castInstToExprConstructor FPTruncInst{} = return FPTruncExpr
castInstToExprConstructor FPExtInst{} = return FPExtExpr
castInstToExprConstructor FPToSIInst{} = return FPToSIExpr
castInstToExprConstructor FPToUIInst{} = return FPToUIExpr
castInstToExprConstructor SIToFPInst{} = return SIToFPExpr
castInstToExprConstructor UIToFPInst{} = return UIToFPExpr
castInstToExprConstructor PtrToIntInst{} = return PtrToIntExpr
castInstToExprConstructor IntToPtrInst{} = return IntToPtrExpr
castInstToExprConstructor BitcastInst{} = return BitcastExpr
castInstToExprConstructor _ = fail ""

castInstToExpr :: Instruction -> BuildExpr Expr
castInstToExpr inst = do
    exprConstructor <- castInstToExprConstructor inst
    value <- valueToExpr $ castedValue inst
    return $ exprConstructor (exprTOfInst inst) value

loadInstToExpr :: (Instruction, Maybe MemlogOp) -> BuildExpr Expr
loadInstToExpr (inst@LoadInst{ loadAddress = addr },
                Just (AddrMemlogOp LoadOp addrEntry)) = do
    info <- lift getInfo
    case addrFlag addrEntry of
        IrrelevantFlag -> irrelevant -- Ignore parts of CPU state that Panda doesn't track.
        _ -> (locExpr <$> maybeToM (M.lookup (MemLoc addrEntry) info)) <|>
             liftM (LoadExpr $ exprTOfInst inst) (return addrEntry)
loadInstToExpr _ = fail ""

gepInstToExpr :: Instruction -> BuildExpr Expr
gepInstToExpr inst@GetElementPtrInst{ _instructionType = instType,
                                      getElementPtrValue = value,
                                      getElementPtrIndices = indices } = do
    valueExpr <- valueToExpr value
    size <- case instType of
        TypePointer (TypeInteger bits) _ -> return $ bits `quot` 8
        other -> trace ("Type failure: " ++ show other) fail ""
    index <- case map valueContent indices of
        [ConstantC (ConstantInt{ constantIntValue = idx })] -> return idx
        other -> trace ("Value failure: " ++ show other) fail ""
    return $ IntToPtrExpr PtrT $ AddExpr (exprTOfInst inst) valueExpr (ILitExpr $ fromIntegral size * index)
gepInstToExpr _ = fail ""

helperInstToExpr :: Instruction -> BuildExpr Expr
helperInstToExpr inst@CallInst{ callFunction = funcValue,
                                callArguments = funcArgs } = do
    case valueContent funcValue of
        ExternalFunctionC (ExternalFunction{ externalFunctionName = funcId })
            | "helper_" `L.isPrefixOf` identifierAsString funcId -> case funcArgs of
                [(argVal, _)] -> do
                    argExpr <- valueToExpr argVal
                    return $ CastHelperExpr (exprTOfInst inst) funcId argExpr
                [(argVal1, _), (argVal2, _)] -> do
                     argExpr1 <- valueToExpr argVal1
                     argExpr2 <- valueToExpr argVal2
                     return $ BinaryHelperExpr (exprTOfInst inst) funcId argExpr1 argExpr2
                _ -> trace ("Bad funcArgs: " ++ (show funcArgs)) $ fail ""
            | otherwise -> fail ""
        _ -> fail ""
helperInstToExpr _ = fail ""

traceInst :: Instruction -> a -> a
traceInst inst = trace ("Couldn't process inst " ++ (show inst))

t :: (Show a) => a -> a
t x = traceShow x x

maybeTraceInst :: Instruction -> a -> a
maybeTraceInst inst@CallInst{} = case valueContent $ callFunction inst of
    ExternalFunctionC func
        | (identifierAsString $ externalFunctionName func) == "log_dynval" -> id
        | otherwise -> traceInst inst
    _ -> traceInst inst
maybeTraceInst inst@StoreInst{ storeIsVolatile = True } = id
maybeTraceInst inst = traceInst inst

(<||>) :: Alternative f => (a -> f b) -> (a -> f b) -> a -> f b
(<||>) f1 f2 a = f1 a <|> f2 a

-- List of ways to process instructions and order in which to try them.
instToExprs :: [Instruction -> BuildExpr Expr]
instToExprs = [ binaryInstToExpr,
                castInstToExpr,
                gepInstToExpr,
                helperInstToExpr ]

memInstToExprs :: [(Instruction, Maybe MemlogOp) -> BuildExpr Expr]
memInstToExprs = [ loadInstToExpr ]

type MaybeSymb = MaybeT (Symbolic)

makeValueContentRelevant :: ValueContent -> Symbolic ()
makeValueContentRelevant (InstructionC inst) = do
    func <- getCurrentFunction
    case instructionName inst of
        Just id -> makeRelevant $ IdLoc func id
        _ -> return ()
makeValueContentRelevant _ = return ()

makeValueRelevant :: Value -> Symbolic ()
makeValueRelevant = makeValueContentRelevant . valueContent

storeUpdate :: (Instruction, Maybe MemlogOp) -> MaybeSymb ()
storeUpdate (inst@StoreInst{ storeIsVolatile = False,
                                  storeValue = val },
                  Just (AddrMemlogOp StoreOp addr)) = do
    -- trace ("STORE: " ++ show inst ++ " ===> " ++ show addr) $ return ()
    value <- buildExprToMaybeExpr $ valueToExpr val
    lift $ infoInsert (MemLoc addr) value
    lift $ makeRelevant $ MemLoc addr
    lift $ makeValueRelevant val
storeUpdate _ = fail ""

exprUpdate :: (Instruction, Maybe MemlogOp) -> MaybeSymb ()
exprUpdate instOp@(inst, _) = do
    id <- maybeToM $ instructionName inst
    func <- lift getCurrentFunction
    let builtExpr = (foldl1 (<||>) instToExprs) inst <|>
                     loadInstToExpr instOp
    expr <- buildExprToMaybeExpr builtExpr
    -- traceShow (id, expr) $ return ()
    lift $ infoInsert (IdLoc func id) (repeatf 5 simplify expr)
    where repeatf 0 f x = trace "repeatf overflow, bailing" x
          repeatf n f x
              | x == f x = x
              | otherwise = repeatf (n - 1) f $ f x 

-- Ignore alloca instructions
nullUpdate :: (Instruction, Maybe MemlogOp) -> MaybeSymb ()
nullUpdate (AllocaInst{}, _) = return ()
nullUpdate _ = fail ""

controlFlowUpdate :: (Instruction, Maybe MemlogOp) -> MaybeSymb ()
controlFlowUpdate (RetInst{ retInstValue = Just val }, _) = do
    lift $ makeValueRelevant val
    lift $ putNextBlock $ Nothing
controlFlowUpdate (UnconditionalBranchInst{ unconditionalBranchTarget = target }, _)
    = lift $ putNextBlock $ Just target
controlFlowUpdate (BranchInst{ branchTrueTarget = trueTarget,
                               branchFalseTarget = falseTarget,
                               branchCondition = cond },
                   Just (BranchOp idx)) = do
    lift $ makeValueRelevant $ cond
    case idx of
        0 -> lift $ putNextBlock $ Just trueTarget
        1 -> lift $ putNextBlock $ Just falseTarget
        _ -> error "Invalid branch index"
controlFlowUpdate _ = fail ""

infoUpdaters :: [(Instruction, Maybe MemlogOp) -> MaybeSymb ()]
infoUpdaters = [ exprUpdate, storeUpdate, controlFlowUpdate, nullUpdate ]

updateInfo :: (Instruction, Maybe MemlogOp) -> Symbolic ()
updateInfo instOp@(inst, _) = void $ runMaybeT $ foldl1 (<||>) infoUpdaters instOp

runBlock :: MemlogMap -> BasicBlock -> Symbolic ()
runBlock memlogMap block = do
    mapM updateInfo instOpList
    nextBlock <- getNextBlock
    case nextBlock of
        Just block -> runBlock memlogMap block
        Nothing -> return ()
    where instOpList = M.findWithDefault (error $ "Couldn't find basic block instruction list for " ++ show (functionName $ basicBlockFunction block) ++ show (basicBlockName block)) block memlogMap

isMemLoc :: Loc -> Bool
isMemLoc MemLoc{} = True
isMemLoc _ = False

runFunction :: MemlogMap -> Info -> Function -> Info
runFunction memlogMap initialInfo f = symbolicInfo state
    where computation = runBlock memlogMap $ head $ functionBody f
          state = execState computation initialState
          initialState = noSymbolicState{ symbolicInfo = initialInfo,
                                          symbolicFunction = f }

runFunctions :: MemlogMap -> [Function] -> Info
runFunctions memlogMap fs = foldl (runFunction memlogMap) M.empty fs

deriving instance Show Constant
deriving instance Show ExternalValue
deriving instance Show GlobalAlias
deriving instance Show GlobalVariable
deriving instance Show BasicBlock
deriving instance Show ValueContent

showInfo :: Info -> String
showInfo = unlines . map showEach . filter doShow . M.toList
    where showEach (key, val) = pretty key ++ " -> " ++ show (locExpr val)
          doShow (_, LocInfo{ locRelevant = False }) = False
          doShow (_, LocInfo{ locExpr = expr }) = doShowExpr expr
          doShowExpr (IrrelevantExpr) = False
          doShowExpr _ = True

data MemlogOp = AddrMemlogOp AddrOp AddrEntry | BranchOp Word32 | SelectOp Bool
    deriving (Eq, Ord, Show)
data AddrOp = LoadOp | StoreOp | BranchAddrOp | SelectAddrOp
    deriving (Eq, Ord, Show, Enum)
data AddrEntry = AddrEntry { addrType :: AddrEntryType
                           , addrVal :: Word64
                           , addrOff :: Word32
                           , addrFlag :: AddrFlag }
    deriving (Eq, Ord, Show)
data AddrEntryType = HAddr | MAddr | IAddr | LAddr | GReg | GSpec | Unk | Const | Ret
    deriving (Eq, Ord, Show, Enum)
data AddrFlag = IrrelevantFlag | NoFlag | ExceptionFlag | ReadlogFlag | FuncargFlag
    deriving (Eq, Ord, Show)

getMemlogEntry :: Get MemlogOp
getMemlogEntry = do
    entryType <- getWord64host
    out <- case entryType of
        0 -> AddrMemlogOp <$> getAddrOp <*> getAddrEntry
        1 -> BranchOp <$> getWord32host <* skip 28
        2 -> SelectOp <$> getBool <* skip 28
    -- traceShow out $ return out
    return out

getBool :: Get Bool
getBool = do
    word32 <- getWord32host
    return $ case word32 of
        0 -> False
        _ -> True

getAddrOp :: Get AddrOp
getAddrOp = (toEnum . fromIntegral) <$> getWord64host

getAddrEntry :: Get AddrEntry
getAddrEntry = AddrEntry <$> ((toEnum . fromIntegral) <$> getWord64host) <*> getWord64host <*> getWord32host <*> getAddrFlag

getAddrFlag :: Get AddrFlag
getAddrFlag = do
    addrFlagType <- getWord32host
    return $ case addrFlagType of
        -1 -> IrrelevantFlag
        0 -> NoFlag
        1 -> ExceptionFlag
        2 -> ReadlogFlag
        3 -> FuncargFlag
        f -> error ("Parse error on flag " ++ show f)

type MemlogMap = M.Map BasicBlock [(Instruction, Maybe MemlogOp)]
type OpContext = State [MemlogOp]
type MemlogContext = StateT (MemlogMap, S.Set String) OpContext
-- Track next basic block to execute
type FuncOpContext = StateT (Maybe BasicBlock) OpContext
memlogPop :: FuncOpContext (Maybe MemlogOp)
memlogPop = do
    stream <- lift get
    case stream of
        op : ops -> lift (put ops) >> return (Just op)
        [] -> return Nothing

memlogPopWithError :: String -> FuncOpContext MemlogOp
memlogPopWithError errMsg = do
    maybeOp <- memlogPop
    case maybeOp of
        Just op -> return op
        Nothing -> error errMsg

memlogPopWithErrorInst :: Instruction -> FuncOpContext MemlogOp
memlogPopWithErrorInst inst = memlogPopWithError $ "Failed on block " ++ (show $ instructionBasicBlock inst)

associateMemlogWithFunc :: Function -> MemlogContext ()
associateMemlogWithFunc func = addBlock $ head $ functionBody func
    where addBlock :: BasicBlock -> MemlogContext ()
          addBlock block = do
              ops <- lift get
              (associated, nextBlock) <- lift $ runStateT (associateBasicBlock block) Nothing
              (map, funcNames) <- get
              if S.member (identifierAsString $ functionName func) funcNames
                  then put (M.insert block associated map, funcNames)
                  else return ()
              case nextBlock of
                  Just nextBlock' -> addBlock nextBlock'
                  Nothing -> return ()

associateBasicBlock :: BasicBlock -> FuncOpContext [(Instruction, Maybe MemlogOp)]
associateBasicBlock = mapM associateInstWithCopy . basicBlockInstructions
    where associateInstWithCopy inst = do
              maybeOp <- associateInst inst
              -- case maybeOp of
              --   Just _ -> trace (show (identifierAsString $ functionName $ basicBlockFunction $ fromJust $ instructionBasicBlock inst) ++ ": " ++ show inst ++ "=> " ++  show maybeOp) $ return ()
              --   _ -> return ()
              return (inst, maybeOp)

associateInst :: Instruction -> FuncOpContext (Maybe MemlogOp)
associateInst inst@LoadInst{} = liftM Just $ memlogPopWithErrorInst inst
associateInst inst@StoreInst{ storeIsVolatile = volatile }
    = if volatile
        then return Nothing
        else liftM Just $ memlogPopWithErrorInst inst
associateInst inst@BranchInst{} = do
    op <- memlogPopWithErrorInst inst
    case op of
        BranchOp branchTaken ->
            if branchTaken == 0
                then put $ Just $ branchTrueTarget inst
                else put $ Just $ branchFalseTarget inst
        _ -> return ()
    return $ Just op
associateInst inst@UnconditionalBranchInst{ unconditionalBranchTarget = target} = do
    put $ Just target
    liftM Just $ memlogPopWithErrorInst inst

associateInst RetInst{} = put Nothing >> return Nothing
associateInst _ = return Nothing

associateFuncs :: [MemlogOp] -> S.Set String -> [Function] -> MemlogMap
associateFuncs ops funcNames funcs = map
    where ((map, _), leftoverOps) = runState inner ops
          inner = execStateT (mapM_ associateMemlogWithFunc funcs) (M.empty, funcNames)

showAssociated :: MemlogMap -> String
showAssociated theMap = L.intercalate "\n\n" $ map showBlock $ M.toList theMap
    where showBlock (block, list) = show (basicBlockName block) ++ ":\n" ++ (L.intercalate "\n" $ map showInstOp list)
          showInstOp (inst, maybeOp) = show inst ++ " => " ++ show maybeOp

takeUntil :: (a -> Bool) -> [a] -> [a]
takeUntil p (x : xs)
    | p x = []
    | otherwise = x : (takeUntil p xs)
takeUntil _ [] = []

interesting :: [String] -> [String]
interesting fs = takeUntil boring $ dropWhile boring fs
    where boring = not . L.isInfixOf "main"

main :: IO ()
main = do
    (Right theMod) <- parseLLVMFile defaultParserOptions "/tmp/llvm-mod.bc"
    funcNameList <- lines <$> readFile "/tmp/llvm-functions.log"
    let mainName = head $ filter (L.isInfixOf "main") funcNameList
    let findFunc name = fromMaybe (error $ "Couldn't find function " ++ name) $ findFunctionByName theMod name
    let funcList = map findFunc funcNameList
    let interestingNames = interesting funcNameList
    let interestingNameSet = S.fromList interestingNames
    let interestingFuncs = map findFunc interestingNames
    memlogBytes <- B.readFile "/tmp/llvm-memlog.log"
    let memlog = runGet (many getMemlogEntry) memlogBytes
    let associated = associateFuncs memlog interestingNameSet funcList
    -- putStrLn $ showAssociated associated
    putStrLn $ showInfo $ runFunctions associated interestingFuncs
