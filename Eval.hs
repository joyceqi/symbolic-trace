{-# LANGUAGE FlexibleInstances, FlexibleContexts, UndecidableInstances, MultiParamTypeClasses, StandaloneDeriving #-}
-- Symbolic evaluator for basic blocks

module Eval(Symbolic(..), SymbolicState(..), noSymbolicState, runBlocks, messages, messagesByIP, warnings, showWarning) where

import Data.LLVM.Types
import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Map.Strict as MS
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Bits as Bits
import Data.Word
import Data.Maybe
import Debug.Trace
import Control.Applicative
import Control.Monad
import Control.Monad.State.Lazy
import Control.Monad.Trans.Class(lift, MonadTrans)
import Control.Monad.Trans.Maybe
-- For progress bar tracking
import System.IO.Unsafe(unsafePerformIO)
import Text.Printf(printf)

import Data.RESET.Types
import AppList
import Expr
import Memlog
import Options
import Pretty

data LocInfo = LocInfo{
    locExpr :: Expr,
    -- Guest instruction address where loc originated
    locOrigin :: Maybe Word64
} deriving (Eq, Ord, Show)

noLocInfo :: LocInfo
noLocInfo = LocInfo{
    locExpr = IrrelevantExpr,
    locOrigin = Nothing
}

deriving instance (Show a) => Show (Message a)

-- Representation of our [partial] knowledge of machine state.
type Info = M.Map Loc LocInfo
data SymbolicState = SymbolicState {
        symbolicInfo :: Info,
        symbolicPreviousBlock :: Maybe BasicBlock,
        symbolicFunction :: Function,
        -- Map of names for free variables: loads from uninitialized memory
        symbolicVarNameMap :: M.Map (ExprT, AddrEntry) String,
        symbolicCurrentIP :: Maybe Word64,
        symbolicWarnings :: AppList (Maybe Word64, String),
        symbolicMessages :: AppList (Maybe Word64, Message Expr),
        symbolicMessagesByIP :: MS.Map Word64 (AppList (Message Expr)),
        symbolicSkipRest :: Bool,
        symbolicRetVal :: Maybe Expr,
        symbolicTotalFuncs :: Int,
        symbolicFuncsProcessed :: Int,
        symbolicOptions :: Options
    } deriving Show

messages :: SymbolicState -> [(Maybe Word64, Message Expr)]
messages = unAppList . symbolicMessages

warnings :: SymbolicState -> [(Maybe Word64, String)]
warnings = unAppList . symbolicWarnings

messagesByIP :: Word64 -> SymbolicState -> [Message Expr]
messagesByIP ip SymbolicState{ symbolicMessagesByIP = msgMap }
    = unAppList $ MS.findWithDefault mkAppList ip msgMap

-- Symbolic is our fundamental monad: it holds state about control flow and
-- holds our knowledge of machine state.
type Symbolic = State SymbolicState

class (MonadState SymbolicState m, Functor m) => Symbolicish m where { }
instance (MonadState SymbolicState m, Functor m) => Symbolicish m

-- Atomic operations inside Symbolic.
getInfo :: Symbolicish m => m Info
getInfo = symbolicInfo <$> get
getPreviousBlock :: Symbolicish m => m (Maybe BasicBlock)
getPreviousBlock = symbolicPreviousBlock <$> get
getCurrentFunction :: Symbolicish m => m Function
getCurrentFunction = symbolicFunction <$> get
getCurrentIP :: Symbolicish m => m (Maybe Word64)
getCurrentIP = symbolicCurrentIP <$> get
getSkipRest :: Symbolicish m => m Bool
getSkipRest = symbolicSkipRest <$> get
getRetVal :: Symbolicish m => m (Maybe Expr)
getRetVal = symbolicRetVal <$> get
putInfo :: Symbolicish m => Info -> m ()
putInfo info = modify (\s -> s{ symbolicInfo = info })
putPreviousBlock :: Symbolicish m => Maybe BasicBlock -> m ()
putPreviousBlock block = modify (\s -> s{ symbolicPreviousBlock = block })
putCurrentFunction :: Symbolicish m => Function -> m ()
putCurrentFunction f = modify (\s -> s{ symbolicFunction = f })
putCurrentIP :: Symbolicish m => Maybe Word64 -> m ()
putCurrentIP newIP = modify (\s -> s{ symbolicCurrentIP = newIP })
putRetVal retVal = modify (\s -> s{ symbolicRetVal = retVal })

getOption :: Symbolicish m => (Options -> a) -> m a
getOption projection = projection <$> symbolicOptions <$> get

whenDebugIP :: Symbolicish m => m () -> m ()
whenDebugIP action = do
    currentIP <- getCurrentIP
    debugIP <- getOption optDebugIP
    case (currentIP, debugIP) of
        (Just ip, Just ip')
            | ip == ip' -> action
        _ -> return ()

skipRest :: Symbolicish m => m ()
skipRest = modify (\s -> s{ symbolicSkipRest = True })
clearSkipRest :: Symbolicish m => m ()
clearSkipRest = modify (\s -> s{ symbolicSkipRest = False })

printIP :: Maybe Word64 -> String
printIP (Just realIP) = printf "%x" realIP
printIP Nothing = "unkown"

getStringIP :: Symbolicish m => m String
getStringIP = printIP <$> getCurrentIP

generateName :: Symbolicish m => ExprT -> AddrEntry -> m (Maybe String)
generateName typ addr@AddrEntry{ addrType = MAddr, addrVal = val } = do
    varNameMap <- getVarNameMap
    case M.lookup (typ, addr) varNameMap of
        Just name -> return $ Just name
        Nothing -> do
            let newName = printf "%s_%04x_%d" (pretty typ) (val `rem` (2 ^ 12)) (M.size varNameMap)
            putVarNameMap $ M.insert (typ, addr) newName varNameMap 
            return $ Just newName
    where getVarNameMap = symbolicVarNameMap <$> get
          putVarNameMap m = modify (\s -> s{ symbolicVarNameMap = m })
generateName _ _ = return Nothing

whenM :: Monad m => m Bool -> m () -> m ()
whenM cond action = cond >>= (flip when) action

inUserCode :: Symbolicish m => m Bool
inUserCode = do
    maybeCurrentIP <- getCurrentIP
    return $ case maybeCurrentIP of
        Just currentIP
            | currentIP >= 2 ^ 32 -> False
        _ -> True

message :: Symbolicish m => Message Expr -> m ()
message msg = do
    whenDebugIP $ trace (printf "\t\tMESSAGE: %s" $ show msg) $ return ()
    maybeIP <- getCurrentIP
    modify (\s -> s{ symbolicMessages = symbolicMessages s +: (maybeIP, msg) })
    case maybeIP of
        Just ip -> do
            modify (\s -> s{ 
                symbolicMessagesByIP = MS.alter addMsg ip $ symbolicMessagesByIP s
            })
        Nothing -> return ()
    where addMsg (Just msgs) = Just $ msgs +: msg
          addMsg Nothing = Just $ singleAppList msg

warning :: Symbolicish m => String -> m ()
warning warn = do
    warnings <- symbolicWarnings <$> get
    ip <- getCurrentIP
    modify (\s -> s{ symbolicWarnings = warnings +: (ip, warn) })
    message $ WarningMessage $ showWarning (ip, warn)

showWarning :: (Maybe Word64, String) -> String
showWarning (ip, s) = printf " - (%s) %s" (printIP ip) s

locInfoInsert :: Symbolicish m => Loc -> LocInfo -> m ()
locInfoInsert key locInfo = do
    info <- getInfo
    putInfo $ M.insert key locInfo info
exprInsert :: Symbolicish m => Loc -> Expr -> m ()
exprInsert key expr = do
    currentIP <- getCurrentIP
    locInfoInsert key LocInfo{ locExpr = expr, locOrigin = currentIP }
exprFindInfo :: Symbolicish m => Expr -> Loc -> m Expr
exprFindInfo def key = locExpr <$> M.findWithDefault defLocInfo key <$> getInfo
    where defLocInfo = noLocInfo{ locExpr = def }

noSymbolicState :: SymbolicState
noSymbolicState = SymbolicState{
    symbolicInfo = M.empty,
    symbolicPreviousBlock = Nothing,
    symbolicFunction = error "No function.",
    symbolicVarNameMap = M.empty,
    symbolicCurrentIP = Nothing,
    symbolicWarnings = mkAppList,
    symbolicMessages = mkAppList,
    symbolicMessagesByIP = M.empty,
    symbolicSkipRest = False,
    symbolicRetVal = Nothing,
    symbolicTotalFuncs = error "Need total instr count.",
    symbolicFuncsProcessed = 0,
    symbolicOptions = defaultOptions
}

valueAt :: Symbolicish m => Loc -> m Expr
valueAt loc = exprFindInfo (InputExpr Int64T loc) loc

-- BuildExpr is a monad for building expressions. It allows us to short-
-- circuit the computation and just return IrrelevantExpr, and it also allows
-- us to return detailed errors (for now this is not implemented).
data BuildExprM a
    = Irrelevant
    | ErrorI String
    | JustI a

newtype BuildExprT m a = BuildExprT { runBuildExprT :: m (BuildExprM a) }

type BuildExpr a = BuildExprT (Symbolic) a

-- Monad transformer boilerplate.
instance (Monad m) => Monad (BuildExprT m) where
    x >>= f = BuildExprT $ do
        v <- runBuildExprT x
        case v of
            JustI y -> runBuildExprT (f y)
            Irrelevant -> return Irrelevant
            ErrorI s -> return $ ErrorI s
    return x = BuildExprT (return $ JustI x)
    fail e = BuildExprT (return $ ErrorI e)

instance (Monad m) => Functor (BuildExprT m) where
    fmap f x = x >>= return . f

instance MonadTrans BuildExprT where
    lift m = BuildExprT $ m >>= return . JustI

irrelevant :: (Monad m) => BuildExprT m a
irrelevant = BuildExprT $ return Irrelevant

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

instance MonadState SymbolicState (BuildExprT Symbolic) where
    state = lift . state

-- Some conversion functions between different monads
buildExprToMaybeExpr :: (Monad m) => BuildExprT m Expr -> MaybeT m Expr
buildExprToMaybeExpr = MaybeT . liftM buildExprMToMaybeExpr . runBuildExprT

buildExprToMaybeTExpr :: (Monad m, MonadTrans t) => BuildExprT m Expr -> MaybeT (t m) Expr
buildExprToMaybeTExpr = MaybeT . lift . liftM buildExprMToMaybeExpr . runBuildExprT

buildExprMToMaybeExpr :: BuildExprM Expr -> Maybe Expr
buildExprMToMaybeExpr (JustI e) = Just e
buildExprMToMaybeExpr (ErrorI s) = Nothing
buildExprMToMaybeExpr Irrelevant = Just IrrelevantExpr

maybeToM :: (Monad m) => Maybe a -> m a
maybeToM (Just x) = return x
maybeToM (Nothing) = fail ""

identifierToExpr :: Identifier -> BuildExpr Expr
identifierToExpr name = do
    func <- getCurrentFunction
    value <- valueAt (idLoc func name)
    case value of
        IrrelevantExpr -> return IrrelevantExpr -- HACK!!! figure out why this is happening
        e -> return e

valueToExpr :: Value -> BuildExpr Expr
valueToExpr (ConstantC UndefValue{}) = return UndefinedExpr
valueToExpr (ConstantC (ConstantFP _ _ value)) = return $ FLitExpr value 
valueToExpr (ConstantC (ConstantInt _ _ value)) = return $ ILitExpr value
valueToExpr (ConstantC (ConstantValue{ constantInstruction = inst }))
    = instToExpr (inst, Nothing)
valueToExpr (InstructionC inst) = do
    name <- case instructionName inst of
        Just n -> return n
        Nothing -> fail "No name for inst"
    identifierToExpr name
valueToExpr (ArgumentC (Argument{ argumentName = name,
                                  argumentType = argType })) = do
    func <- getCurrentFunction
    identifierToExpr name <|>
        (return $ InputExpr (typeToExprT argType) (idLoc func name))
valueToExpr (GlobalVariableC GlobalVariable{ globalVariableName = name,
                                             globalVariableType = varType }) = do
    func <- getCurrentFunction
    return $ InputExpr (typeToExprT varType) (idLoc func name)
valueToExpr (ExternalValueC ExternalValue{ externalValueName = name,
                                           externalValueType = valType }) = do
    func <- getCurrentFunction
    return $ InputExpr (typeToExprT valType) (idLoc func name)
valueToExpr val = warning ("Couldn't find expr for " ++ show val) >> fail ""

maybeValueToExpr :: Value -> MaybeSymb Expr
maybeValueToExpr = buildExprToMaybeExpr . valueToExpr

lookupValue :: Value -> BuildExpr Expr
lookupValue val = do
    expr <- valueToExpr val
    loc <- case expr of
        InputExpr _ loc' -> return loc'
        _ -> fail ""
    valueAt loc

-- Decide whether or not to tell the user about a load or a store.
interestingOp :: Expr -> AddrEntry -> Bool
interestingOp _ AddrEntry{ addrFlag = IrrelevantFlag } = False
interestingOp _ AddrEntry{ addrType = GReg, addrVal = reg }
    | reg >= 16 = False
interestingOp _ _ = True

findIncomingValue :: BasicBlock -> [(Value, Value)] -> Value
findIncomingValue prevBlock valList
    = pairListFind test (error err) $ map swap valList
    where err = printf "Couldn't find block in list:\n%s" (show valList)
          swap (a, b) = (b, a)
          test (BasicBlockC block) = block == prevBlock
          test _ = False

typeBytes :: Type -> Integer
typeBytes (TypePointer _ _) = 8
typeBytes (TypeInteger bits) = fromIntegral bits `quot` 8
typeBytes (TypeArray count t) = fromIntegral count * typeBytes t
typeBytes (TypeStruct _ ts _) = sum $ map typeBytes ts
typeBytes t = error $ printf "Unsupported type %s" (show t)

modifyAt :: Int -> a -> [a] -> [a]
modifyAt 0 v (_ : xs) = v : xs
modifyAt n v (x : xs) = x : modifyAt (n - 1) v xs

binaryInstToExpr :: (ExprT -> Expr -> Expr -> Expr) -> Instruction -> BuildExpr Expr
binaryInstToExpr constructor inst = constructor (exprTOfInst inst)
    <$> valueToExpr (binaryLhs inst) <*> valueToExpr (binaryRhs inst)

castInstToExpr :: (ExprT -> Expr -> Expr) -> Instruction -> BuildExpr Expr
castInstToExpr constructor inst
    = constructor (exprTOfInst inst) <$> valueToExpr (castedValue inst)

instToExpr :: (Instruction, Maybe MemlogOp) -> BuildExpr Expr
instToExpr (inst@AddInst{}, _) = binaryInstToExpr AddExpr inst
instToExpr (inst@SubInst{}, _) = binaryInstToExpr SubExpr inst
instToExpr (inst@MulInst{}, _) = binaryInstToExpr MulExpr inst
instToExpr (inst@DivInst{}, _) = binaryInstToExpr DivExpr inst
instToExpr (inst@RemInst{}, _) = binaryInstToExpr RemExpr inst
instToExpr (inst@ShlInst{}, _) = binaryInstToExpr ShlExpr inst
instToExpr (inst@LshrInst{}, _) = binaryInstToExpr LshrExpr inst
instToExpr (inst@AshrInst{}, _) = binaryInstToExpr AshrExpr inst
instToExpr (inst@AndInst{}, _) = binaryInstToExpr AndExpr inst
instToExpr (inst@OrInst{}, _) = binaryInstToExpr OrExpr inst
instToExpr (inst@XorInst{}, _) = binaryInstToExpr XorExpr inst
instToExpr (inst@TruncInst{}, _) = castInstToExpr TruncExpr inst
instToExpr (inst@ZExtInst{}, _) = castInstToExpr ZExtExpr inst
instToExpr (inst@SExtInst{}, _) = castInstToExpr SExtExpr inst
instToExpr (inst@FPTruncInst{}, _) = castInstToExpr FPTruncExpr inst
instToExpr (inst@FPExtInst{}, _) = castInstToExpr FPExtExpr inst
instToExpr (inst@FPToSIInst{}, _) = castInstToExpr FPToSIExpr inst
instToExpr (inst@FPToUIInst{}, _) = castInstToExpr FPToUIExpr inst
instToExpr (inst@SIToFPInst{}, _) = castInstToExpr SIToFPExpr inst
instToExpr (inst@UIToFPInst{}, _) = castInstToExpr UIToFPExpr inst
instToExpr (inst@PtrToIntInst{}, _) = castInstToExpr PtrToIntExpr inst
instToExpr (inst@IntToPtrInst{}, _) = castInstToExpr IntToPtrExpr inst
instToExpr (inst@BitcastInst{}, _) = castInstToExpr BitcastExpr inst
instToExpr (PhiNode{ phiIncomingValues = valList }, _) = do
    maybePrevBlock <- getPreviousBlock
    let prevBlock = fromMaybe (error "No previous block!") maybePrevBlock
    valueToExpr $ findIncomingValue prevBlock valList
instToExpr (GetElementPtrInst{}, _) = return GEPExpr
instToExpr (inst@CallInst{ callFunction = ExternalFunctionC func,
                           callArguments = argValuePairs }, _)
    | externalIsIntrinsic func = do
        args <- mapM valueToExpr $ map fst argValuePairs
        return $ IntrinsicExpr (exprTOfInst inst) func args
instToExpr (inst@InsertValueInst{ insertValueAggregate = aggr,
                                  insertValueValue = val,
                                  insertValueIndices = [idx] }, _) = do
    aggrExpr <- valueToExpr aggr
    insertExpr <- valueToExpr val
    let typ = exprTOfInst inst
    case aggrExpr of
        UndefinedExpr -> case typ of
            StructT ts -> return $ StructExpr typ $ modifyAt idx insertExpr $
                replicate (length ts) UndefinedExpr
            _ -> warning "Bad result type!" >> fail ""
        StructExpr t es -> return $ StructExpr t $ modifyAt idx insertExpr es
        _ -> warning (printf "Unrecognized expr at inst '%s'" (show inst)) >> fail ""
instToExpr (inst@ExtractValueInst{ extractValueAggregate = aggr,
                                   extractValueIndices = [idx] }, _) = do
    aggrExpr <- valueToExpr aggr
    return $ ExtractExpr (exprTOfInst inst) idx aggrExpr
instToExpr (inst@ICmpInst{ cmpPredicate = pred,
                           cmpV1 = val1,
                           cmpV2 = val2 }, _) = do
    expr1 <- valueToExpr val1
    expr2 <- valueToExpr val2
    return $ ICmpExpr pred expr1 expr2
instToExpr (inst@LoadInst{ loadAddress = addrValue },
            Just (AddrMemlogOp LoadOp addrEntry)) = do
    info <- getInfo
    let typ = exprTOfInst inst
    expr <- (locExpr <$> maybeToM (M.lookup (MemLoc addrEntry) info)) <|>
            (LoadExpr typ addrEntry <$> generateName typ addrEntry)
    stringIP <- getStringIP
    origin <- optional $ deIntToPtr <$> valueToExpr addrValue
    when (interestingOp expr addrEntry) $
        message $ MemoryMessage LoadOp (pretty addrEntry) expr origin
    return expr
instToExpr (inst@SelectInst{ selectTrueValue = trueVal,
                             selectFalseValue = falseVal },
            Just (SelectOp selection))
    = valueToExpr $ if selection == 0 then trueVal else falseVal
instToExpr _ = fail ""

(<||>) :: Alternative f => (a -> f b) -> (a -> f b) -> a -> f b
(<||>) f1 f2 a = f1 a <|> f2 a
deIntToPtr :: Expr -> Expr
deIntToPtr (IntToPtrExpr _ e) = e
deIntToPtr e = e

-- For info updates that might fail, with the intention of no change
-- if the monad comes back Nothing.
type MaybeSymb = MaybeT (Symbolic)

exprUpdate :: (Instruction, Maybe MemlogOp) -> MaybeSymb ()
exprUpdate instOp@(inst, _) = do
    id <- maybeToM $ instructionName inst
    func <- getCurrentFunction
    expr <- buildExprToMaybeExpr $ instToExpr instOp
    exprInsert (idLoc func id) expr

otherUpdate :: (Instruction, Maybe MemlogOp) -> MaybeSymb ()
otherUpdate (AllocaInst{}, _) = return ()
otherUpdate (CallInst{ callFunction = ExternalFunctionC func}, _)
    | (identifierContent $ externalFunctionName func) == T.pack "log_dynval" = return ()
otherUpdate (inst@StoreInst{ storeIsVolatile = False,
                             storeValue = val,
                             storeAddress = addrValue },
             (Just (AddrMemlogOp StoreOp addr))) = do
    value <- maybeValueToExpr val
    origin <- optional $ deIntToPtr <$> maybeValueToExpr addrValue
    when (interestingOp value addr) $
        message $ MemoryMessage StoreOp (pretty addr) value origin
    exprInsert (MemLoc addr) value
-- This will trigger twice with each IP update, but that's okay because the
-- second one is the one we want.
otherUpdate (StoreInst{ storeIsVolatile = True,
                        storeValue = val }, _) = do
    ip <- case valueContent val of
        ConstantC (ConstantInt{ constantIntValue = ipVal }) -> return ipVal
        _ -> warning "Failed to update IP" >> fail ""
    putCurrentIP $ Just $ fromIntegral $ ip
otherUpdate (RetInst{ retInstValue = Just val }, _) = do
    expr <- maybeValueToExpr val
    putRetVal $ Just expr
otherUpdate (RetInst{}, _) = return ()
otherUpdate (UnconditionalBranchInst{}, _)
    = message UnconditionalBranchMessage
otherUpdate (BranchInst{ branchTrueTarget = trueTarget,
                         branchFalseTarget = falseTarget,
                         branchCondition = cond },
             Just (BranchOp idx)) = void $ optional $ do
    condExpr <- maybeValueToExpr cond
    message $ BranchMessage condExpr (idx == 0)
otherUpdate (SwitchInst{}, _) = return ()
otherUpdate (CallInst{ callFunction = ExternalFunctionC func,
                       callAttrs = attrs }, _)
    | FANoReturn `elem` externalFunctionAttrs func = skipRest
    | FANoReturn `elem` attrs = skipRest
    | T.pack "cpu_loop_exit" == identifierContent (externalFunctionName func)
        = skipRest
-- FIXME: Implement a more reasonable model for "real" memcpy/memset
-- (i.e. those that are for arrays, not structs)
otherUpdate (CallInst{ callFunction = ExternalFunctionC func,
                       callArguments = [_, (value, _), (lenValue, _), _, _] },
             Just (MemsetOp addr)) = do
    val <- maybeValueToExpr value
    lenExpr <- maybeValueToExpr lenValue
    len <- case lenExpr of
        ILitExpr len' -> return len'
        _ -> warning "Can't extract memset length" >> fail ""
    currentExpr <- valueAt (MemLoc addr)
    case currentExpr of
        StructExpr{} -> warning "Zeroing struct"
        _
            | len > 16 -> warning "Array memset"
            | otherwise -> return ()
    exprInsert (MemLoc addr) val
otherUpdate (CallInst{ callFunction = ExternalFunctionC func,
                       callArguments = [_, _, (lenValue, _), _, _] },
             Just (MemcpyOp src dest)) = do
    lenExpr <- maybeValueToExpr lenValue
    len <- case lenExpr of
        ILitExpr len' -> return len'
        _ -> warning "Can't extract memcpy length" >> fail ""
    srcExpr <- valueAt $ MemLoc src
    case srcExpr of
        StructExpr{} -> return ()
        _
            | len > 16 -> warning "Array memcpy"
            | otherwise -> return ()
    exprInsert (MemLoc dest) srcExpr
otherUpdate (UnreachableInst{}, _) = warning "UNREACHABLE INSTRUCTION!"
otherUpdate _ = fail ""

warnInstOp :: Symbolicish m => (Instruction, Maybe MemlogOp) -> m ()
warnInstOp (inst, op)
    = warning $ printf "Couldn't process inst '%s' with op %s"
        (show inst) (show op)

traceInstOp :: (Instruction, Maybe MemlogOp) -> a -> a
traceInstOp (inst, Just (HelperFuncOp _))
    = trace $ printf "%s\n=============\nHELPER FUNCTION:" (show inst)
traceInstOp (inst, Just op) = trace $ printf "%s\n\t\t%s" (show inst) (show op)
traceInstOp (inst, Nothing) = traceShow inst

helperFuncUpdate :: (Instruction, Maybe MemlogOp) -> MaybeSymb ()
helperFuncUpdate (inst@CallInst{ callArguments = argVals,
                                 callFunction = FunctionC func },
                  Just (HelperFuncOp memlog)) = do
    -- Call stack abstraction; store current function so we can restore it later
    currentFunc <- getCurrentFunction
    -- Pass arguments through
    argExprs <- mapM (buildExprToMaybeExpr . valueToExpr . fst) argVals
    let argNames = map argumentName $ functionParameters func
    let locs = map (idLoc func) argNames
    let argLocInfos = [ noLocInfo{ locExpr = e } | e <- argExprs ]
    zipWithM locInfoInsert locs argLocInfos 
    -- Run and grab return value
    maybeRetVal <- runBlocks memlog
    -- Understand return value
    optional $ do
        val <- maybeToM $ maybeRetVal
        id <- maybeToM $ instructionName inst
        currentIP <- getCurrentIP
        let locInfo = noLocInfo{ locExpr = val, locOrigin = currentIP }
        locInfoInsert (idLoc currentFunc id) locInfo
    -- Restore old function
    putCurrentFunction currentFunc
helperFuncUpdate _ = fail ""

progress :: Monad m => Float -> m ()
progress f = seq (unsafePerformIO $ putStr $ printf "\r%.0f%%" $ 100 * f) $ return ()

countFunction :: MaybeSymb ()
countFunction = do
    funcs <- symbolicFuncsProcessed <$> get
    total <- symbolicTotalFuncs <$> get
    when (funcs `rem` (total `quot` 100) == 0) $ 
        progress $ fromIntegral funcs / fromIntegral total
    modify (\s -> s{ symbolicFuncsProcessed = funcs + 1 })

updateInfo :: (Instruction, Maybe MemlogOp) -> MaybeSymb ()
updateInfo instOp@(inst, _) = do
    currentIP <- getCurrentIP
    whenDebugIP $ traceInstOp instOp $ return ()
    skip <- getSkipRest
    unless skip $ void $ helperFuncUpdate instOp <|>
        exprUpdate instOp <|> otherUpdate instOp <|>
        (warnInstOp instOp >> fail "")

runBlock :: (BasicBlock, InstOpList) -> MaybeSymb (Maybe Expr)
runBlock (block, instOpList) = do
    putCurrentFunction $ basicBlockFunction block 
    when (identifierContent (basicBlockName block) == T.pack "entry")
        countFunction
    putRetVal Nothing
    clearSkipRest
    mapM updateInfo instOpList
    putPreviousBlock $ Just block
    getRetVal

isMemLoc :: Loc -> Bool
isMemLoc MemLoc{} = True
isMemLoc _ = False

runBlocks :: MemlogList -> MaybeSymb (Maybe Expr)
runBlocks blocks = do
    retVals <- mapM runBlock blocks
    return $ last retVals

showInfo :: Info -> String
showInfo = unlines . map showEach . filter doShow . M.toList
    where showEach (key, val) = printf "%s %s-> %s" (pretty key) origin (show (locExpr val))
              where origin = fromMaybe "" $ printf "(from %x) " <$> locOrigin val
          doShow (IdLoc{}, LocInfo{ locExpr = expr }) = doShowExpr expr
          doShow (MemLoc{}, LocInfo{ locExpr = IrrelevantExpr }) = False
          doShow _ = True
          doShowExpr IrrelevantExpr = False
          doShowExpr ILitExpr{} = False
          doShowExpr LoadExpr{} = False
          doShowExpr InputExpr{} = True
          doShowExpr expr = True
