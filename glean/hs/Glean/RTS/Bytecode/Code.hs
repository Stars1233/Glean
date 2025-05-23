{-
  Copyright (c) Meta Platforms, Inc. and affiliates.
  All rights reserved.

  This source code is licensed under the BSD-style license found in the
  LICENSE file in the root directory of this source tree.
-}

module Glean.RTS.Bytecode.Code
  ( Code
  , Register
  , Label
  , CodeGen
  , OutputSupply
  , Many(..)
  , Optimised(..)
  , Meta(..)
  , literal
  , label
  , issue
  , issueEndBlock
  , constant
  , local
  , output
  , outputUninitialized
  , generate
  , castRegister
  , callSite
  , calledFrom
  , fullScan
  , vlog
  ) where

import Control.Exception (assert)
import Control.Monad
import Control.Monad.Fix (MonadFix(..))
import Control.Monad.ST (ST, runST)
import Control.Monad.Trans
import qualified Control.Monad.Trans.State.Strict as S
import Data.Bits
import Data.ByteString (ByteString)
import Data.Functor
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.List (mapAccumL, sortBy)
import Data.Maybe
import Data.Ord
import qualified Data.Vector as V
import qualified Data.Vector.Primitive as VP
import qualified Data.Vector.Primitive.Mutable as VPM
import qualified Data.Vector.Storable as VS
import Data.Word (Word64)
import GHC.Stack
import qualified Util.Log as Log

import Glean.Bytecode.Types
import Glean.RTS.Types (Pid)
import Glean.RTS.Bytecode.Gen.Instruction
import Glean.RTS.Bytecode.Supply
import Glean.RTS.Foreign.Bytecode (Subroutine, subroutine)

-- | A basic block
newtype Block = Block
  { -- | Instructions (reversed)
    blockInsns :: [Insn]
  }

data CodeS = CodeS
  { -- | Label of current block
    csLabel :: {-# UNPACK #-} !Label

    -- | Instructions in current block (reversed)
  , csInsns :: [Insn]

    -- | Blocks produced so far (reversed)
  , csBlocks :: [Block]

    -- | All constant values used by the subroutine. These will be preloaded
    -- into registers at the start.
  , csConstants :: [Word64]

    -- | Cached `length csConstants`
  , csNextConstant :: !(Register 'Word)

    -- | Map known constants to their registers
  , csConstantMap :: IntMap (Register 'Word)

    -- | All literals in the subroutine.
  , csLiterals :: HashMap ByteString Word64

    -- | Cached `length csLiterals`
  , csLiteralsSize :: !Word64

    -- | Currently used number of local registers
  , csNextLocal :: {-# UNPACK #-} !(Register 'Word)

    -- | Maximum number of local registers used so far
  , csMaxLocal :: {-# UNPACK #-} !(Register 'Word)

    -- | Currently used number of binary::Output registers
  , csNextOutput :: {-# UNPACK #-} !(Register 'BinaryOutputPtr)

    -- | Maximum number of binary::Output registers
  , csMaxOutputs :: {-# UNPACK #-} !(Register 'BinaryOutputPtr)

    -- | Predicates we perform full scans on.
    -- Repeated entries mean multiple scans of the same predicate
  , csFullScans:: [Pid]
  }

-- | Code gen monad
newtype Code a = Code { runCode :: S.StateT CodeS IO a }
  deriving(Functor, Applicative, Monad, MonadFix)

-- | Things that generate code of the form
-- > Register t1 -> ... -> Register tn -> Code a
--
class CodeGen s cg where
  genCode :: cg -> S.State s (Code (CodeResult cg))

instance CodeGen s (Code a) where
  genCode = pure

instance (Supply a s, CodeGen s cg) => CodeGen s (a -> cg) where
  genCode f = S.state supply >>= genCode . f

-- | Allocate `n` registers where `n` isn't statically known.
-- Example:
--
-- local $ Many n $ \regs -> ...
data Many a cg = Many Int ([a] -> cg)

instance (Supply a s, CodeGen s cg) => CodeGen s (Many a cg) where
  genCode (Many n f) = replicateM n (S.state supply) >>= genCode . f

type family CodeResult cg
type instance CodeResult (Code a) = a
type instance CodeResult (a -> cg) = CodeResult cg
type instance CodeResult (Many a cg) = CodeResult cg

-- | Load a constant value into a register. This will happen at the start of
-- the subroutine, effectively giving us a poor man's version of constant
-- hoisting.
constant :: Word64 -> Code (Register 'Word)
constant w = Code $ do
  s@CodeS{..} <- S.get
  case IntMap.lookup (fromIntegral w) csConstantMap of
    Just r -> return r
    Nothing -> do
      S.put s
        { csConstants = w : csConstants
        , csNextConstant = succ csNextConstant
        , csConstantMap =
            IntMap.insert (fromIntegral w) csNextConstant csConstantMap
        }
      return csNextConstant

-- | Generate a chunk of code with reserved fresh registers. The registers can
-- be reused afterwards.
local :: CodeGen RegSupply cg => cg -> Code (CodeResult cg)
local = runLocal
  regSupply
  csNextLocal
  (\r s -> s { csNextLocal = r })
  (\r s -> s { csMaxLocal = max (csMaxLocal s) r })

-- | Supply of @Register 'BinaryOutputPtr@ (cf. 'output').
newtype OutputSupply = OutputSupply RegSupply
  deriving (Supply (Register 'BinaryOutputPtr))

-- | Declare registers of type @Register 'BinaryOutputPtr@.  The registers
-- are inputs to the subroutine. Use 'resetOutput' to reset the byte array
-- stored in these registers to empty.
outputUninitialized :: CodeGen OutputSupply cg => cg -> Code (CodeResult cg)
outputUninitialized = runLocal
  (OutputSupply . regSupply)
  csNextOutput
  (\r s -> s { csNextOutput = r })
  (\r s -> s { csMaxOutputs = max (csMaxOutputs s) r })

output :: (Register 'BinaryOutputPtr -> Code a) -> Code a
output f = outputUninitialized $ \out -> do
  issue $ ResetOutput out
  f out

runLocal
  :: (Supply r s, CodeGen s cg)
  => (r -> s)
  -> (CodeS -> r)
  -> (r -> CodeS -> CodeS)
  -> (r -> CodeS -> CodeS)
  -> cg
  -> Code (CodeResult cg)
runLocal make get set setmax cg = do
  r <- Code $ S.gets get
  let (gen, sup) = S.runState (genCode cg) $ make r
      !next = peekSupply sup
  Code $ S.modify' $ setmax next . set next
  x <- gen
  Code $ S.modify' $ set r
  return x

-- | Poor man's function calls
--
-- * Put the label of the return address into a register with
--   'loadReg', jump to the code, and return with 'jumpReg'.
--
-- * We have to avoid local registers at the call site(s) clashing
--   with local registers in the called code.  So 'callSite' remembers
--   the number of locals in scope at the call site(s) and
--   'calledCode' uses the high-water mark of the call sites as the
--   base for its local registers.
--
data CallSite = CallSite
  { callSiteNextLocal :: Register 'Word
  , callSiteNextOutput :: Register 'BinaryOutputPtr
  }

callSite :: Code CallSite
callSite = do
  CodeS{..} <- Code S.get
  return (CallSite csNextLocal csNextOutput)

calledFrom :: [CallSite] -> Code a -> Code a
calledFrom frames inner = do
  CodeS{..} <- Code S.get
  Code $ S.modify' $ \s -> s
    { csNextLocal = maximum (map callSiteNextLocal frames)
    , csNextOutput = maximum (map callSiteNextOutput frames) }
  x <- inner
  Code $ S.modify' $ \s -> s
    { csNextLocal = csNextLocal
    , csNextOutput = csNextOutput }
  return x

-- | Register that a query statement performs a full scan over a predicate.
fullScan :: Pid -> Code ()
fullScan pid = Code $ S.modify' $ \s -> s { csFullScans = pid : csFullScans s }

data Optimised = Optimised | Unoptimised
  deriving(Eq,Ord,Enum,Bounded,Show)

-- | Metadata about the subroutine
newtype Meta = Meta
  { meta_fullScans :: [Pid]
  }

-- | Generate a 'Subroutine', allocating input registers as necessary.
-- Example:
--
-- generate $ \reg1 reg2 -> do
--   add reg1 reg2 reg1
--   ret
--
generate
  :: (CodeGen RegSupply cg, CodeResult cg ~ ())
  => Optimised -> cg -> IO (Meta, Subroutine t)
generate opt cg = do
  let (gen, sup) = S.runState (genCode cg) $ regSupply $ register Input 0
      !nextInput = peekSupply sup
  ((), CodeS{..}) <- S.runStateT (runCode gen) CodeS
        { csLabel = Label 0
        , csInsns = []
        , csBlocks = []
        , csConstants = []
        , csConstantMap = IntMap.empty
        , csNextConstant = register Constant 0
        , csLiterals = HashMap.empty
        , csLiteralsSize = 0
        , csNextLocal = register Local 0
        , csMaxLocal = register Local 0
        , csNextOutput = castRegister nextInput
        , csMaxOutputs = castRegister nextInput
        , csFullScans = mempty }
      -- sanity check
  when (not $ null csInsns) $ fail "unterminated basic block"
  let -- output registers go after input registers
      finalInputSize = registerIndex csMaxOutputs
      constantsSize = registerIndex csNextConstant
      get_label pc label =
        let addr = offsets VP.! fromLabel label
        in assert (addr /= maxBound) $ addr - pc
      get_reg :: forall ty . Register ty -> Word64
      get_reg r = case registerSegment r of
        Input -> assert (n < finalInputSize) n
        Constant -> assert (n < constantsSize) (n + finalInputSize)
        Local -> n + finalInputSize + constantsSize
        where
          !n = registerIndex r
      optimise = case opt of
        Optimised -> shortcut
        Unoptimised -> id
      (insns, offsets) = layout $ optimise CFG
        { cfgBlocks = V.fromListN (fromLabel csLabel) $ reverse csBlocks
        , cfgEntry = Label 0
        }
      code = concat $ snd $ mapAccumL
        (\offset insn ->
          let !next = offset + insnSize insn
          in
          (next, insnWords get_reg (get_label next) insn))
        0
        insns
      meta = Meta csFullScans
  (meta,) <$> subroutine
    (VS.fromListN (length code) code)
    finalInputSize
    (finalInputSize - registerIndex nextInput)
    (registerIndex csMaxLocal + constantsSize)
    (reverse csConstants)
    (map fst $ sortBy (comparing snd) $ HashMap.toList csLiterals)


-- | Control flow graph
data CFG = CFG
  { -- | Basic blocks
    cfgBlocks :: !(V.Vector Block)

    -- | Entry block
  , cfgEntry :: {-# UNPACK #-} !Label
  }

-- | Inline blocks containing only one instruction and short-circuit labels
-- which point to blocks consisting of a single Jump.
--
-- NOTE: This will leave behind unreachable blocks.
shortcut :: CFG -> CFG
shortcut cfg@CFG{..}
  | V.all isNothing shortcuts = cfg
  | otherwise = CFG
      { cfgBlocks = V.imap
          (\i Block{..} ->
              Block { blockInsns = mapLabels relabel <$> inline i blockInsns })
          cfgBlocks
      , cfgEntry = relabel cfgEntry
      }
  where
    inline i _
      | Just insn <- shortcuts V.! i = [insn]
    inline _ (Jump target : insns)
      | Just insn <- shortcuts V.! fromLabel target = insn : insns
    inline _ insns = insns

    -- FIXME: This can loop if the generated code contains infinite loops
    shortcuts = cfgBlocks <&> \Block{..} -> case blockInsns of
      [insn] -> Just $ case insn of
        Jump target | Just insn' <- shortcuts V.! fromLabel target -> insn'
        _ -> insn
      _ -> Nothing

    relabel label
      | Just (Jump target) <- shortcuts V.! fromLabel label = target
      | otherwise = label

data Layout s = Layout
  { -- | Current offset in the instruction stream
    layoutOffset :: {-# UNPACK #-} !Word64

    -- | Label offsets, 'maxBound' for blocks which haven't been emitted yet
  , layoutLabels :: !(VPM.STVector s Word64)

    -- | Insn stream (all reversed)
  , layoutInsns :: [[Insn]]

    -- | Blocks we want to emit (some of them might have been emitted already)
  , layoutTodo :: !IntSet
  }

-- | Compute a flat instruction stream for a subroutine as well as a mapping
-- from labels to their offsets in that stream. Note that we don't emit
-- unreachable blocks - a block that hasn't been emitted because it's dead will
-- have the magic value of maxBound in the label->offset mapping.
--
-- This is really simple at the moment.
--
-- * Start with the entry block.
-- * If the current block ends with an unconditional jump and the block it jumps
--   to hasn't been emitted yet, continue with that block, thus saving the jump.
-- * Otherwise, continue with the unemitted block with lowest label number.
--
-- There is obviously ample room for improvement here.
layout :: CFG -> ([Insn], VP.Vector Word64)
layout CFG{..} = runST $ do
  mlabels <- VPM.replicate (V.length cfgBlocks) maxBound
  emit cfgEntry Layout
    { layoutOffset = 0
    , layoutLabels = mlabels
    , layoutInsns = []
    , layoutTodo = IntSet.empty
    }
  where
    -- Emit a specific block which must not have been emitted already
    emit :: Label -> Layout s -> ST s ([Insn], VP.Vector Word64)
    emit !label layout@Layout{..} = do
      VPM.write layoutLabels (fromLabel label) layoutOffset

      case blockInsns (cfgBlocks V.! fromLabel label) of
        -- Handle unconditional jumps specially
        Jump target : insns -> do
          s <- stillTodo layout target
          if s
            then emit target $ addInsns insns layout
            else emitNext $ addInsns (Jump target : insns) layout

        insns -> emitNext $ addInsns insns layout

    -- Emit the numerically lowest unemitted block (if any)
    emitNext :: Layout s -> ST s ([Insn], VP.Vector Word64)
    emitNext layout@Layout{..}
      | Just (label, todo) <- IntSet.minView layoutTodo = do
          s <- stillTodo layout $ Label label
          (if s then emit (Label label) else emitNext) layout{layoutTodo = todo}
      | otherwise = do
          labels <- VP.unsafeFreeze layoutLabels
          return (reverse $ concat layoutInsns, labels)

    -- Has a block already been emitted
    stillTodo :: Layout s -> Label -> ST s Bool
    stillTodo Layout{..} label =
      (== maxBound) <$> VPM.read layoutLabels (fromLabel label)

    -- Emit instructions
    addInsns :: [Insn] -> Layout s -> Layout s
    addInsns insns !layout = layout
      { layoutOffset = layoutOffset layout + sum (map insnSize insns)
      , layoutTodo = foldr
          (IntSet.insert . fromLabel)
          (layoutTodo layout)
          (concatMap insnLabels insns)
      , layoutInsns = insns : layoutInsns layout
      }

-- | Frame segment which a register belongs to
data Segment = Input | Constant | Local
  deriving(Eq,Ord,Enum,Bounded,Show)

-- A register has a 'Segment' and an index within the segment, packed into
-- a word.

-- | Create a register with the given 'Segment' and index
register :: Segment -> Word64 -> Register a
register s i = Register $ (fromIntegral (fromEnum s) `shiftL` 62) .|. i

-- | Get the 'Segment' of the register
registerSegment :: Register a  -> Segment
registerSegment (Register i) = toEnum $ fromIntegral (i `shiftR` 62)

-- | Get the index of the register within its segment
registerIndex :: Register a -> Word64
registerIndex (Register i) = i .&. 0x3FFFFFFFFFFFFFFF

-- | Start a new basic block. The previous block will be terminated by the
-- supplied unconditional jump instruction or, if none is provided, by a jump
-- to the new block.
newBlock :: Maybe Insn -> Code ()
newBlock terminator = Code $ do
  s@CodeS{..} <- S.get
  let !label = succ csLabel
      insn = fromMaybe (Jump label) terminator
  S.put $! s
    { csLabel = label
    , csInsns = []
    , csBlocks = Block (insn : csInsns) : csBlocks
    }

-- | Add a literal to the literal table and yield its index
literal :: ByteString -> Code Literal
literal lit = Code $ Literal . fromIntegral <$> do
  m <- S.gets csLiterals
  case HashMap.lookup lit m of
    Just n -> return n
    Nothing -> do
      n <- S.gets csLiteralsSize
      S.modify' $ \s@CodeS{..} -> s
        { csLiterals = HashMap.insert lit n csLiterals
        , csLiteralsSize = csLiteralsSize + 1 }
      return n

-- | Yield a label for the current position in the code
label :: Code Label
label = do
  insns <- Code $ S.gets csInsns
  when (not $ null insns) $ newBlock Nothing
  Code $ S.gets csLabel

-- | Issue an instruction which doesn't modify the program counter
issue :: Insn -> Code ()
issue insn = Code $ S.modify' $ \s@CodeS{..} -> s { csInsns = insn : csInsns }

-- | Issue an instruction which always modifies the program counter
issueEndBlock :: Insn -> Code ()
issueEndBlock = newBlock . Just

-- | Make some noise during code generation. Helpful for debugging.
--
vlog :: HasCallStack => String -> Code ()
vlog msg = Code $ lift (Log.vlog 2 msg)
