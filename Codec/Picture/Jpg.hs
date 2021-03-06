{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -fspec-constr-count=5 #-}
-- | Module used for JPEG file loading and writing.
module Codec.Picture.Jpg( readJpeg, decodeJpeg, encodeJpeg ) where

import Control.Applicative( (<$>), (<*>))
import Control.Monad( when, replicateM, forM, forM_, foldM_, unless )
import Control.Monad.ST( ST, runST )
import Control.Monad.Trans( lift )
import qualified Control.Monad.Trans.State.Strict as S

import Data.List( find, foldl' )
import Data.Bits( (.|.), (.&.), shiftL, shiftR )
import Data.Int( Int16, Int32 )
import Data.Word(Word8, Word16, Word32)
import Data.Serialize( Serialize(..), Get, Put
                     , getWord8, putWord8
                     , getWord16be, putWord16be
                     , remaining, lookAhead, skip
                     , getBytes, decode, runPut
                     , encode
                     )
import Data.Maybe( fromJust )
import qualified Data.Vector.Storable as V
import qualified Data.Vector.Storable.Mutable as M
import Data.Array.Unboxed( Array, UArray, elems, listArray)
import qualified Data.ByteString as B

import Codec.Picture.Types
import Codec.Picture.Jpg.Types
import Codec.Picture.Jpg.DefaultTable
import Codec.Picture.Jpg.FastIdct
import Codec.Picture.Jpg.FastDct


--------------------------------------------------
----            Types
--------------------------------------------------
data JpgFrameKind =
      JpgBaselineDCTHuffman
    | JpgExtendedSequentialDCTHuffman
    | JpgProgressiveDCTHuffman
    | JpgLosslessHuffman
    | JpgDifferentialSequentialDCTHuffman
    | JpgDifferentialProgressiveDCTHuffman
    | JpgDifferentialLosslessHuffman
    | JpgExtendedSequentialArithmetic
    | JpgProgressiveDCTArithmetic
    | JpgLosslessArithmetic
    | JpgDifferentialSequentialDCTArithmetic
    | JpgDifferentialProgressiveDCTArithmetic
    | JpgDifferentialLosslessArithmetic
    | JpgQuantizationTable
    | JpgHuffmanTableMarker
    | JpgStartOfScan
    | JpgAppSegment Word8
    | JpgExtensionSegment Word8

    | JpgRestartInterval
    deriving (Eq, Show)


data JpgFrame =
      JpgAppFrame        !Word8 B.ByteString
    | JpgExtension       !Word8 B.ByteString
    | JpgQuantTable      ![JpgQuantTableSpec]
    | JpgHuffmanTable    ![(JpgHuffmanTableSpec, HuffmanTree)]
    | JpgScanBlob        !JpgScanHeader !B.ByteString
    | JpgScans           !JpgFrameKind !JpgFrameHeader
    | JpgIntervalRestart !Word16
    deriving Show

data JpgFrameHeader = JpgFrameHeader
    { jpgFrameHeaderLength   :: !Word16
    , jpgSamplePrecision     :: !Word8
    , jpgHeight              :: !Word16
    , jpgWidth               :: !Word16
    , jpgImageComponentCount :: !Word8
    , jpgComponents          :: [JpgComponent]
    }
    deriving Show

instance SizeCalculable JpgFrameHeader where
    calculateSize hdr = 2 + 1 + 2 + 2 + 1 
                      + sum [calculateSize c | c <- jpgComponents hdr]

data JpgComponent = JpgComponent
    { componentIdentifier       :: !Word8
      -- | Stored with 4 bits
    , horizontalSamplingFactor  :: !Word8
      -- | Stored with 4 bits
    , verticalSamplingFactor    :: !Word8
    , quantizationTableDest     :: !Word8
    }
    deriving Show

instance SizeCalculable JpgComponent where
    calculateSize _ = 3

data JpgImage = JpgImage { jpgFrame :: [JpgFrame]}
    deriving Show

data JpgScanSpecification = JpgScanSpecification
    { componentSelector :: !Word8
      -- | Encoded as 4 bits
    , dcEntropyCodingTable :: !Word8
      -- | Encoded as 4 bits
    , acEntropyCodingTable :: !Word8

    }
    deriving Show

instance SizeCalculable JpgScanSpecification where
    calculateSize _ = 2

data JpgScanHeader = JpgScanHeader
    { scanLength :: !Word16
    , scanComponentCount :: !Word8
    , scans :: [JpgScanSpecification]

      -- | (begin, end)
    , spectralSelection    :: (Word8, Word8)

      -- | Encoded as 4 bits
    , successiveApproxHigh :: !Word8

      -- | Encoded as 4 bits
    , successiveApproxLow :: !Word8
    }
    deriving Show

instance SizeCalculable JpgScanHeader where
    calculateSize hdr = 2 + 1
                      + sum [calculateSize c | c <- scans hdr]
                      + 2
                      + 1
    
data JpgQuantTableSpec = JpgQuantTableSpec
    { -- | Stored on 4 bits
      quantPrecision     :: !Word8

      -- | Stored on 4 bits
    , quantDestination   :: !Word8

    , quantTable         :: MacroBlock Int16
    }
    deriving Show

-- | Type introduced only to avoid some typeclass overlapping
-- problem
newtype TableList a = TableList [a]

class SizeCalculable a where
    calculateSize :: a -> Int

instance (SizeCalculable a, Serialize a) => Serialize (TableList a) where
    put (TableList lst) = do
        putWord16be . fromIntegral $ sum [calculateSize table | table <- lst]
        mapM_ put lst

    get = TableList <$> (getWord16be >>= \s -> innerParse (fromIntegral s - 2))
      where innerParse :: Int -> Get [a]
            innerParse 0    = return []
            innerParse size = do
                onStart <- fromIntegral <$> remaining
                table <- get
                onEnd <- fromIntegral <$> remaining
                (table :) <$> innerParse (size - (onStart - onEnd))

instance SizeCalculable JpgQuantTableSpec where
    calculateSize table =
        1 + (fromIntegral (quantPrecision table) + 1) * 64

instance Serialize JpgQuantTableSpec where
    put table = do
        let precision = quantPrecision table
        put4BitsOfEach precision (quantDestination table)
        forM_ (V.toList $ quantTable table) $ \coeff ->
            if precision == 0 then putWord8 $ fromIntegral coeff
                             else putWord16be $ fromIntegral coeff

    get = do
        (precision, dest) <- get4BitOfEach
        coeffs <- replicateM 64 $ if precision == 0
                then fromIntegral <$> getWord8
                else fromIntegral <$> getWord16be
        return JpgQuantTableSpec
            { quantPrecision = precision
            , quantDestination = dest
            , quantTable = V.fromListN 64 coeffs
            }

data JpgHuffmanTableSpec = JpgHuffmanTableSpec
    { -- | 0 : DC, 1 : AC, stored on 4 bits
      huffmanTableClass       :: !DctComponent
      -- | Stored on 4 bits
    , huffmanTableDest        :: !Word8

    , huffSizes :: !(UArray Word32 Word8)
    , huffCodes :: !(Array Word32 (UArray Int Word8))
    }
    deriving Show

buildPackedHuffmanTree :: Array Word32 (UArray Int Word8) -> HuffmanTree
buildPackedHuffmanTree = buildHuffmanTree . map elems . elems

-- | Decode a list of huffman values, not optimized for speed, but it
-- should work.
huffmanDecode :: HuffmanTree -> BoolReader s Word8
huffmanDecode originalTree = getNextBit >>= huffDecode originalTree
  where huffDecode Empty                   _ = return 0
        huffDecode (Branch (Leaf v) _) False = return v
        huffDecode (Branch l       _ ) False = getNextBit >>= huffDecode l
        huffDecode (Branch _ (Leaf v)) True  = return v
        huffDecode (Branch _       r ) True  = getNextBit >>= huffDecode r
        huffDecode (Leaf v) _ = return v

-- |  Drop all bit until the bit of indice 0, usefull to parse restart
-- marker, as they are byte aligned, but Huffman might not.
byteAlign :: BoolReader s ()
byteAlign = do
  (idx, _, chain) <- S.get
  when (idx /= 7) (setDecodedString chain)

-- | Bitify a list of things to decode.
setDecodedString :: B.ByteString -> BoolReader s ()
setDecodedString str = case B.uncons str of
     Nothing        -> S.put (maxBound, 0, B.empty)
     Just (0xFF, rest) -> case B.uncons rest of
            Nothing                  -> S.put (maxBound, 0, B.empty)
            Just (0x00, afterMarker) -> S.put (7, 0xFF, afterMarker)
            Just (_   , afterMarker) -> setDecodedString afterMarker
     Just (v, rest) -> S.put (       7, v,    rest)

{-# INLINE getNextBit #-}
getNextBit :: BoolReader s Bool
getNextBit = do
    (idx, v, chain) <- S.get
    let val = (v .&. (1 `shiftL` idx)) /= 0
    if idx == 0
      then setDecodedString chain
      else S.put (idx - 1, v, chain)
    return val

--------------------------------------------------
----            Serialization instances
--------------------------------------------------
commonMarkerFirstByte :: Word8
commonMarkerFirstByte = 0xFF

checkMarker :: Word8 -> Word8 -> Get ()
checkMarker b1 b2 = do
    rb1 <- getWord8
    rb2 <- getWord8
    when (rb1 /= b1 || rb2 /= b2)
         (fail "Invalid marker used")

eatUntilCode :: Get ()
eatUntilCode = do
    code <- lookAhead getWord8
    unless (code == 0xFF)
           (skip 1 >> eatUntilCode)

instance SizeCalculable JpgHuffmanTableSpec where
    calculateSize table = 1 + 16 + sum [fromIntegral e | e <- elems $ huffSizes table]

instance Serialize JpgHuffmanTableSpec where
    put = error "Unimplemented"
    get = do
        (huffClass, huffDest) <- get4BitOfEach
        sizes <- replicateM 16 getWord8
        codes <- forM sizes $ \s -> do
            let si = fromIntegral s
            listArray (0, si - 1) <$> replicateM (fromIntegral s) getWord8
        return JpgHuffmanTableSpec
            { huffmanTableClass =
                if huffClass == 0 then DcComponent else AcComponent
            , huffmanTableDest = huffDest
            , huffSizes = listArray (0, 15) sizes
            , huffCodes = listArray (0, 15) codes
            }

instance Serialize JpgImage where
    put = error "Unimplemented"
    get = do
        let startOfImageMarker = 0xD8
            -- endOfImageMarker = 0xD9
        checkMarker commonMarkerFirstByte startOfImageMarker
        eatUntilCode
        frames <- parseFrames
        {-checkMarker commonMarkerFirstByte endOfImageMarker-}
        return JpgImage { jpgFrame = frames }

takeCurrentFrame :: Get B.ByteString
takeCurrentFrame = do
    size <- getWord16be
    getBytes (fromIntegral size - 2)

parseFrames :: Get [JpgFrame]
parseFrames = do
    kind <- get
    case kind of
        JpgAppSegment c ->
            (\frm lst -> JpgAppFrame c frm : lst) <$> takeCurrentFrame <*> parseFrames
        JpgExtensionSegment c ->
            (\frm lst -> JpgExtension c frm : lst) <$> takeCurrentFrame <*> parseFrames
        JpgQuantizationTable ->
            (\(TableList quants) lst -> JpgQuantTable quants : lst) <$> get <*> parseFrames
        JpgRestartInterval ->
            (\(RestartInterval i) lst -> JpgIntervalRestart i : lst) <$> get <*> parseFrames
        JpgHuffmanTableMarker ->
            (\(TableList huffTables) lst ->
                    JpgHuffmanTable [(t, buildPackedHuffmanTree $ huffCodes t) | t <- huffTables] : lst)
                    <$> get <*> parseFrames
        JpgStartOfScan ->
            (\frm imgData -> [JpgScanBlob frm imgData])
                            <$> get <*> (remaining >>= getBytes)

        _ -> (\hdr lst -> JpgScans kind hdr : lst) <$> get <*> parseFrames

secondStartOfFrameByteOfKind :: JpgFrameKind -> Word8
secondStartOfFrameByteOfKind JpgBaselineDCTHuffman = 0xC0
secondStartOfFrameByteOfKind JpgExtendedSequentialDCTHuffman = 0xC1
secondStartOfFrameByteOfKind JpgProgressiveDCTHuffman = 0xC2
secondStartOfFrameByteOfKind JpgLosslessHuffman = 0xC3
secondStartOfFrameByteOfKind JpgDifferentialSequentialDCTHuffman = 0xC5
secondStartOfFrameByteOfKind JpgDifferentialProgressiveDCTHuffman = 0xC6
secondStartOfFrameByteOfKind JpgDifferentialLosslessHuffman = 0xC7
secondStartOfFrameByteOfKind JpgExtendedSequentialArithmetic = 0xC9
secondStartOfFrameByteOfKind JpgProgressiveDCTArithmetic = 0xCA
secondStartOfFrameByteOfKind JpgLosslessArithmetic = 0xCB
secondStartOfFrameByteOfKind JpgHuffmanTableMarker = 0xC4
secondStartOfFrameByteOfKind JpgDifferentialSequentialDCTArithmetic = 0xCD
secondStartOfFrameByteOfKind JpgDifferentialProgressiveDCTArithmetic = 0xCE
secondStartOfFrameByteOfKind JpgDifferentialLosslessArithmetic = 0xCF
secondStartOfFrameByteOfKind JpgQuantizationTable = 0xDB
secondStartOfFrameByteOfKind JpgStartOfScan = 0xDA
secondStartOfFrameByteOfKind JpgRestartInterval = 0xDD
secondStartOfFrameByteOfKind (JpgAppSegment a) = a
secondStartOfFrameByteOfKind (JpgExtensionSegment a) = a

instance Serialize JpgFrameKind where
    put v = putWord8 0xFF >> put (secondStartOfFrameByteOfKind v)
    get = do
        word <- getWord8
        word2 <- getWord8
        when (word /= 0xFF) (do leftData <- remaining
                                fail $ "Invalid Frame marker (" ++ show word
                                    ++ ", remaining : " ++ show leftData ++ ")")
        return $ case word2 of
            0xC0 -> JpgBaselineDCTHuffman
            0xC1 -> JpgExtendedSequentialDCTHuffman
            0xC2 -> JpgProgressiveDCTHuffman
            0xC3 -> JpgLosslessHuffman
            0xC4 -> JpgHuffmanTableMarker
            0xC5 -> JpgDifferentialSequentialDCTHuffman
            0xC6 -> JpgDifferentialProgressiveDCTHuffman
            0xC7 -> JpgDifferentialLosslessHuffman
            0xC9 -> JpgExtendedSequentialArithmetic
            0xCA -> JpgProgressiveDCTArithmetic
            0xCB -> JpgLosslessArithmetic
            0xCD -> JpgDifferentialSequentialDCTArithmetic
            0xCE -> JpgDifferentialProgressiveDCTArithmetic
            0xCF -> JpgDifferentialLosslessArithmetic
            0xDA -> JpgStartOfScan
            0xDB -> JpgQuantizationTable
            0xDD -> JpgRestartInterval
            a | a >= 0xF0 -> JpgExtensionSegment a
              | a >= 0xE0 -> JpgAppSegment a
              | otherwise -> error ("Invalid frame marker (" ++ show a ++ ")")

put4BitsOfEach :: Word8 -> Word8 -> Put
put4BitsOfEach a b = put $ (a `shiftL` 4) .|. b

get4BitOfEach :: Get (Word8, Word8)
get4BitOfEach = do
    val <- get
    return ((val `shiftR` 4) .&. 0xF, val .&. 0xF)

newtype RestartInterval = RestartInterval Word16

instance Serialize RestartInterval where
    put (RestartInterval i) = putWord16be 4 >> putWord16be i
    get = do
        size <- getWord16be
        when (size /= 4) (fail "Invalid jpeg restart interval size")
        RestartInterval <$> getWord16be

instance Serialize JpgComponent where
    get = do
        ident <- getWord8
        (horiz, vert) <- get4BitOfEach
        quantTableIndex <- getWord8
        return JpgComponent
            { componentIdentifier = ident
            , horizontalSamplingFactor = horiz
            , verticalSamplingFactor = vert
            , quantizationTableDest = quantTableIndex
            }
    put v = do
        put $ componentIdentifier v
        put4BitsOfEach (horizontalSamplingFactor v) $ verticalSamplingFactor v
        put $ quantizationTableDest v

instance Serialize JpgFrameHeader where
    get = do
        beginOffset <- remaining
        frmHLength <- getWord16be
        samplePrec <- getWord8
        h <- getWord16be
        w <- getWord16be
        compCount <- getWord8
        components <- replicateM (fromIntegral compCount) get
        endOffset <- remaining
        when (beginOffset - endOffset < fromIntegral frmHLength)
             (skip $ fromIntegral frmHLength - (beginOffset - endOffset))
        return JpgFrameHeader
            { jpgFrameHeaderLength = frmHLength
            , jpgSamplePrecision = samplePrec
            , jpgHeight = h
            , jpgWidth = w
            , jpgImageComponentCount = compCount
            , jpgComponents = components
            }

    put v = do
        putWord16be $ jpgFrameHeaderLength v
        putWord8    $ jpgSamplePrecision v
        putWord16be $ jpgHeight v
        putWord16be $ jpgWidth v
        putWord8    $ jpgImageComponentCount v
        mapM_ put   $ jpgComponents v

instance Serialize JpgScanSpecification where
    put v = do
        put $ componentSelector v
        put4BitsOfEach (dcEntropyCodingTable v) $ acEntropyCodingTable v

    get = do
        compSel <- get
        (dc, ac) <- get4BitOfEach
        return JpgScanSpecification {
            componentSelector = compSel
          , dcEntropyCodingTable = dc
          , acEntropyCodingTable = ac
          }

instance Serialize JpgScanHeader where
    get = do
        thisScanLength <- getWord16be
        compCount <- getWord8
        comp <- replicateM (fromIntegral compCount) get
        specBeg <- get
        specEnd <- get
        (approxHigh, approxLow) <- get4BitOfEach
        return JpgScanHeader {
            scanLength = thisScanLength,
            scanComponentCount = compCount,
            scans = comp,
            spectralSelection = (specBeg, specEnd),
            successiveApproxHigh = approxHigh,
            successiveApproxLow = approxLow
        }

    put v = do
        put $ scanLength v
        put $ scanComponentCount v
        mapM_ put $ scans v
        put . fst $ spectralSelection v
        put . snd $ spectralSelection v
        put4BitsOfEach (successiveApproxHigh v) $ successiveApproxLow v

-- | Current bit index, current value, string
type BoolState = (Int, Word8, B.ByteString)

type BoolReader s a = S.StateT BoolState (ST s) a

type BoolWriteState = (Put, Word8, Int)
type BoolWriter s a = S.StateT BoolWriteState (ST s) a

writeBits :: Word32 -> Int -> BoolWriter s ()
writeBits bitData bitCount = S.get >>= serialize
  where serialize (str, currentWord, count)
            | bitCount + count == 8 =
                let newVal = fromIntegral $ (currentWord `shiftR` bitCount) .|. fromIntegral bitData
                in S.put (str >> putWord8 newVal, 0, 0)

            | bitCount + count < 8 =
                let newVal = fromIntegral $ (currentWord `shiftR` bitCount)
                in S.put (str, newVal .|. fromIntegral bitData, count + bitCount)

            | otherwise =
                let leftBitCount = 8 - count
                    highPart = fromIntegral $ bitCount `shiftL` (bitCount - leftBitCount)
                    prevPart = currentWord `shiftR` leftBitCount

                    nextMask = 1 `shiftR` (bitCount - leftBitCount) - 1
                    newData = bitData .&. nextMask
                    newCount = bitCount - leftBitCount

                    toWrite = fromIntegral $ prevPart .|. highPart
                in S.put (str >> putWord8 toWrite, 0, 0) 
                        >> writeBits newData newCount
    
quantize :: MacroBlock Int16 -> MutableMacroBlock s Int16
         -> ST s (MutableMacroBlock s Int16)
quantize table = mutate (\idx val -> val `div` (table !!! idx))

-- | Apply a quantization matrix to a macroblock
{-# INLINE deQuantize #-}
deQuantize :: MacroBlock Int16 -> MutableMacroBlock s Int16
           -> ST s (MutableMacroBlock s Int16)
deQuantize table = mutate (\ix val -> val * (table !!! ix))

inverseDirectCosineTransform :: MutableMacroBlock s Int16
                             -> ST s (MutableMacroBlock s Int16)
inverseDirectCosineTransform mBlock =
    fastIdct mBlock >>= mutableLevelShift

zigZagOrder :: MacroBlock Word8
zigZagOrder = makeMacroBlock $ concat
    [[ 0, 1, 5, 6,14,15,27,28]
    ,[ 2, 4, 7,13,16,26,29,42]
    ,[ 3, 8,12,17,25,30,41,43]
    ,[ 9,11,18,24,31,40,44,53]
    ,[10,19,23,32,39,45,52,54]
    ,[20,22,33,38,46,51,55,60]
    ,[21,34,37,47,50,56,59,61]
    ,[35,36,48,49,57,58,62,63]
    ]

zigZagReorder :: MutableMacroBlock s Int16 -> ST s (MutableMacroBlock s Int16)
zigZagReorder block = do
    zigzaged <- M.replicate 64 0
    let update i =  do
            let idx = zigZagOrder !!! i
            v <- block .!!!. fromIntegral idx
            (zigzaged .<-. i) v

        reorder 63 = update 63
        reorder i  = update i >> reorder (i + 1)

    reorder 0
    return zigzaged


-- | This is one of the most important function of the decoding,
-- it form the barebone decoding pipeline for macroblock. It's all
-- there is to know for macro block transformation
decodeMacroBlock :: MacroBlock DctCoefficients
                 -> MutableMacroBlock s Int16
                 -> ST s (MutableMacroBlock s Int16)
decodeMacroBlock quantizationTable block =
    deQuantize quantizationTable block >>= zigZagReorder
                                       >>= inverseDirectCosineTransform

packInt :: [Bool] -> Int32
packInt = foldl' bitStep 0
    where bitStep acc True = (acc `shiftL` 1) + 1
          bitStep acc False = acc `shiftL` 1

-- | Unpack an int of the given size encoded from MSB to LSB.
unpackInt :: Int32 -> BoolReader s Int32
unpackInt bitCount = packInt <$> replicateM (fromIntegral bitCount) getNextBit

powerOf :: Int32 -> Int32
powerOf 0 = 0
powerOf n = limit initial 1
    where initial = if n < 0 then (-1) else 1
          limit range i | range < n = i
          limit range i = limit (2 * range) (i + 1)

encodeInt :: HuffmanWriterCode -> Int32 -> BoolWriter s ()
encodeInt _codeTable n = writeBits (fromIntegral ssss) 4
    where ssss = powerOf n

decodeInt :: Int32 -> BoolReader s Int32
decodeInt ssss = do
    signBit <- getNextBit
    let dataRange = 1 `shiftL` fromIntegral (ssss - 1)
        leftBitCount = ssss - 1
    -- First following bits store the sign of the coefficient, and counted in
    -- SSSS, so the bit count for the int, is ssss - 1
    if signBit
       then (\w -> dataRange + fromIntegral w) <$> unpackInt leftBitCount
       else (\w -> 1 - dataRange * 2 + fromIntegral w) <$> unpackInt leftBitCount

dcCoefficientDecode :: HuffmanTree -> BoolReader s DcCoefficient
dcCoefficientDecode dcTree = do
    ssss <- huffmanDecode dcTree
    if ssss == 0
       then return 0
       else fromIntegral <$> decodeInt (fromIntegral ssss)

-- | Assume the macro block is initialized with zeroes
acCoefficientsDecode :: HuffmanTree -> MutableMacroBlock s Int16
                     -> BoolReader s (MutableMacroBlock s Int16)
acCoefficientsDecode acTree mutableBlock = parseAcCoefficient 1 >> return mutableBlock
  where parseAcCoefficient n | n >= 64 = return ()
                             | otherwise = do
            rrrrssss <- huffmanDecode acTree
            let rrrr = fromIntegral $ (rrrrssss `shiftR` 4) .&. 0xF
                ssss =  rrrrssss .&. 0xF
            case (rrrr, ssss) of
                (  0, 0) -> return ()
                (0xF, 0) -> parseAcCoefficient (n + 16)
                _        -> do
                    decoded <- fromIntegral <$> decodeInt (fromIntegral ssss)
                    lift $ (mutableBlock .<-. (n + rrrr)) decoded
                    parseAcCoefficient (n + rrrr + 1)

-- | Decompress a macroblock from a bitstream given the current configuration
-- from the frame.
decompressMacroBlock :: HuffmanTree         -- ^ Tree used for DC coefficient
                     -> HuffmanTree         -- ^ Tree used for Ac coefficient
                     -> MacroBlock Int16    -- ^ Current quantization table
                     -> DcCoefficient       -- ^ Previous dc value
                     -> BoolReader s (DcCoefficient, MutableMacroBlock s Int16)
decompressMacroBlock dcTree acTree quantizationTable previousDc = do
    dcDeltaCoefficient <- dcCoefficientDecode dcTree
    block <- lift createEmptyMutableMacroBlock
    let neoDcCoefficient = previousDc + dcDeltaCoefficient
    lift $ (block .<-. 0) neoDcCoefficient
    fullBlock <- acCoefficientsDecode acTree block
    decodedBlock <- lift $ decodeMacroBlock quantizationTable fullBlock
    return (neoDcCoefficient, decodedBlock)

gatherQuantTables :: JpgImage -> [JpgQuantTableSpec]
gatherQuantTables img = concat [t | JpgQuantTable t <- jpgFrame img]

gatherHuffmanTables :: JpgImage -> [(JpgHuffmanTableSpec, HuffmanTree)]
gatherHuffmanTables img = concat [lst | JpgHuffmanTable lst <- jpgFrame img]

gatherScanInfo :: JpgImage -> (JpgFrameKind, JpgFrameHeader)
gatherScanInfo img = fromJust $ unScan <$> find scanDesc (jpgFrame img)
    where scanDesc (JpgScans _ _) = True
          scanDesc _ = False

          unScan (JpgScans a b) = (a,b)
          unScan _ = error "If this can happen, the JPEG image is ill-formed"

pixelClamp :: Int16 -> Word8
pixelClamp n = fromIntegral . min 255 $ max 0 n

-- | Given a size coefficient (how much a pixel span horizontally
-- and vertically), the position of the macroblock, return a list
-- of indices and value to be stored in an array (like the final
-- image)
unpackMacroBlock :: Int    -- ^ Component count
                 -> Int    -- ^ Component index
                 -> Int -- ^ Width coefficient
                 -> Int -- ^ Height coefficient
                 -> Int -- ^ x
                 -> Int -- ^ y
                 -> MutableImage s PixelYCbCr8
                 -> MutableMacroBlock s Int16
                 -> ST s ()
    -- Simple case, a macroblock value => a pixel
unpackMacroBlock compCount compIdx  wCoeff hCoeff x y 
                 (MutableImage { mutableImageWidth = imgWidth,
                                 mutableImageHeight = imgHeight, mutableImageData = img })
                 block =
  forM_ pixelIndices $ \(i, j, wDup, hDup) -> do
      let xPos = (i + x * 8) * wCoeff + wDup
          yPos = (j + y * 8) * hCoeff + hDup
      when (0 <= xPos && xPos < imgWidth && 0 <= yPos && yPos < imgHeight)
           (do compVal <- pixelClamp <$> (block .!!!. (i + j * 8))
               let mutableIdx = (xPos + yPos * imgWidth) * compCount + compIdx
               (img .<-. mutableIdx) compVal)

    where pixelIndices = [(i, j, wDup, hDup) | i <- [0 .. 7], j <- [0 .. 7]
                                -- Repetition to spread macro block
                                , wDup <- [0 .. wCoeff - 1]
                                , hDup <- [0 .. hCoeff - 1]
                                ]

-- | Type only used to make clear what kind of integer we are carrying
-- Might be transformed into newtype in the future
type DcCoefficient = Int16

-- | Same as for DcCoefficient, to provide nicer type signatures
type DctCoefficients = DcCoefficient

decodeRestartInterval :: BoolReader s Int32
decodeRestartInterval = return (-1) {-  do
  bits <- replicateM 8 getNextBit
  if bits == replicate 8 True
     then do
         marker <- replicateM 8 getNextBit
         return $ packInt marker
     else return (-1)
        -}


decodeImage :: Int                        -- ^ Component count
            -> JpegDecoder s              -- ^ Function to call to decode an MCU
            -> MutableImage s PixelYCbCr8 -- ^ Result image to write into
            -> BoolReader s ()
decodeImage compCount decoder img = do
    let blockIndices = [(x,y) | y <- [0 ..   verticalMcuCount decoder - 1]
                              , x <- [0 .. horizontalMcuCount decoder - 1] ]
        mcuDecode = mcuDecoder decoder
        blockBeforeRestart = restartInterval decoder

        folder f = foldM_ f blockBeforeRestart blockIndices

    dcArray <- lift (M.replicate compCount 0  :: ST s (M.STVector s DcCoefficient))
    folder (\resetCounter (x,y) -> do
        when (resetCounter == 0)
             (do forM_ [0.. compCount - 1] $
                     \c -> lift $ (dcArray .<-. c) 0
                 byteAlign
                 _restartCode <- decodeRestartInterval
                 -- if 0xD0 <= restartCode && restartCode <= 0xD7
                 return ())

        forM_ mcuDecode $ \(comp, dataUnitDecoder) -> do
            dc <- lift $ dcArray .!!!. comp
            dcCoeff <- dataUnitDecoder x y img $ fromIntegral dc
            lift $ (dcArray .<-. comp) dcCoeff
            return ()

        if resetCounter /= 0 then return $ resetCounter - 1
                                         -- we use blockBeforeRestart - 1 to count
                                         -- the current MCU
                            else return $ blockBeforeRestart - 1)

-- | Type of a data unit (as in the ITU 81) standard
type DataUnitDecoder s  =
    (Int, Int -> Int -> MutableImage s PixelYCbCr8 -> DcCoefficient -> BoolReader s DcCoefficient)

data JpegDecoder s = JpegDecoder
    { restartInterval    :: Int
    , horizontalMcuCount :: Int
    , verticalMcuCount   :: Int
    , mcuDecoder         :: [DataUnitDecoder s]
    }

allElementsEqual :: (Eq a) => [a] -> Bool
allElementsEqual []     = True
allElementsEqual (x:xs) = all (== x) xs

-- | An MCU (Minimal coded unit) is an unit of data for all components
-- (Y, Cb & Cr), taking into account downsampling.
buildJpegImageDecoder :: JpgImage -> JpegDecoder s
buildJpegImageDecoder img = JpegDecoder { restartInterval = mcuBeforeRestart
                                        , horizontalMcuCount = horizontalBlockCount
                                        , verticalMcuCount = verticalBlockCount
                                        , mcuDecoder = mcus }
  where huffmans = gatherHuffmanTables img
        huffmanForComponent dcOrAc dest =
            head [t | (h,t) <- huffmans, huffmanTableClass h == dcOrAc
                                       , huffmanTableDest h == dest]

        mcuBeforeRestart = case [i | JpgIntervalRestart i <- jpgFrame img] of
            []    -> maxBound -- HUUUUUUGE value (enough to parse all MCU)
            (x:_) -> fromIntegral x

        quants = gatherQuantTables img
        quantForComponent dest =
            head [quantTable q | q <- quants, quantDestination q == dest]

        hdr = head [h | JpgScanBlob h _ <- jpgFrame img]

        (_, scanInfo) = gatherScanInfo img
        imgWidth = fromIntegral $ jpgWidth scanInfo
        imgHeight = fromIntegral $ jpgHeight scanInfo

        blockSizeOfDim fullDim maxBlockSize = block + (if rest /= 0 then 1 else 0)
                where (block, rest) = fullDim `divMod` maxBlockSize

        horizontalSamplings = [horiz | (horiz, _, _, _, _) <- componentsInfo]

        imgComponentCount = fromIntegral $ jpgImageComponentCount scanInfo
        isImageLumanOnly = imgComponentCount == 1
        maxHorizFactor | not isImageLumanOnly &&
                            not (allElementsEqual horizontalSamplings) = maximum horizontalSamplings
                       | otherwise = 1

        verticalSamplings = [vert | (_, vert, _, _, _) <- componentsInfo]
        maxVertFactor | not isImageLumanOnly &&
                            not (allElementsEqual verticalSamplings) = maximum verticalSamplings
                      | otherwise = 1

        horizontalBlockCount =
           blockSizeOfDim imgWidth $ fromIntegral (maxHorizFactor * 8)

        verticalBlockCount =
           blockSizeOfDim imgHeight $ fromIntegral (maxVertFactor * 8)

        fetchTablesForComponent component = (horizCount, vertCount, dcTree, acTree, qTable)
            where idx = componentIdentifier component
                  descr = head [c | c <- scans hdr, componentSelector c  == idx]
                  dcTree = huffmanForComponent DcComponent $ dcEntropyCodingTable descr
                  acTree = huffmanForComponent AcComponent $ acEntropyCodingTable descr
                  qTable = quantForComponent $ if idx == 1 then 0 else 1
                  horizCount = if not isImageLumanOnly
                        then fromIntegral $ horizontalSamplingFactor component
                        else 1
                  vertCount = if not isImageLumanOnly
                        then fromIntegral $ verticalSamplingFactor component
                        else 1

        componentsInfo = map fetchTablesForComponent $ jpgComponents scanInfo

        mcus = [(compIdx, \x y writeImg dc -> do
                           (dcCoeff, block) <- decompressMacroBlock dcTree acTree qTable dc
                           lift $ unpacker (x * horizCount + xd) (y * vertCount + yd) writeImg block
                           return dcCoeff)
                     | (compIdx, (horizCount, vertCount, dcTree, acTree, qTable))
                                   <- zip [0..] componentsInfo
                     , let xScalingFactor = maxHorizFactor - horizCount + 1
                           yScalingFactor = maxVertFactor - vertCount + 1
                     , yd <- [0 .. vertCount - 1]
                     , xd <- [0 .. horizCount - 1]
                     , let unpacker = unpackMacroBlock imgComponentCount compIdx 
                                                    xScalingFactor yScalingFactor
                     ]

-- | Try to load a jpeg file and decompress. The colorspace is still
-- YCbCr if you want to perform computation on the luma part. You can
-- convert it to RGB using 'colorSpaceConversion'
readJpeg :: FilePath -> IO (Either String DynamicImage)
readJpeg f = decodeJpeg <$> B.readFile f

-- | Try to decompress a jpeg file and decompress. The colorspace is still
-- YCbCr if you want to perform computation on the luma part. You can
-- convert it to RGB using 'colorSpaceConversion'
--
-- This function can output the following pixel types :
--
--    * PixelY8
--
--    * PixelYCbCr8
--
decodeJpeg :: B.ByteString -> Either String DynamicImage
decodeJpeg file = case decode file of
  Left err -> Left err
  Right img -> case compCount of
                 1 -> Right . ImageY8 $ Image imgWidth imgHeight pixelData
                 3 -> Right . ImageYCbCr8 $ Image imgWidth imgHeight pixelData
                 _ -> Left "Wrong component count"

      where (imgData:_) = [d | JpgScanBlob _kind d <- jpgFrame img]
            (_, scanInfo) = gatherScanInfo img
            compCount = length $ jpgComponents scanInfo

            imgWidth = fromIntegral $ jpgWidth scanInfo
            imgHeight = fromIntegral $ jpgHeight scanInfo

            imageSize = imgWidth * imgHeight * compCount

            pixelData = runST $ V.unsafeFreeze =<< S.evalStateT (do
                resultImage <- lift $ M.replicate imageSize 0
                let wrapped = MutableImage imgWidth imgHeight resultImage
                setDecodedString imgData
                decodeImage compCount (buildJpegImageDecoder img) wrapped
                return resultImage) (-1, 0, B.empty)

extractBlock :: Image PixelYCbCr8       -- ^ Source image
             -> MutableMacroBlock s Int16      -- ^ Mutable block where to put extracted block
             -> Int                     -- ^ Plane
             -> Int                     -- ^ X sampling factor
             -> Int                     -- ^ Y sampling factor
             -> Int                     -- ^ Sample per pixel
             -> Int                     -- ^ Block x
             -> Int                     -- ^ Block y
             -> ST s (MutableMacroBlock s Int16)
extractBlock (Image { imageWidth = w, imageHeight = h, imageData = src })
             block 1 1 sampCount plane bx by | (bx * 8) + 7 < w && (by * 8) + 7 < h = do
    let baseReadIdx = (by * 8 * w) + bx * 8
    sequence_ [(block .<-. (y * 8 + x)) val
                        | y <- [0 .. 7]
                        , let blockReadIdx = baseReadIdx + y * w
                        , x <- [0 .. 7]
                        , let val = fromIntegral $ src !!! ((blockReadIdx + x) * sampCount + plane)
                        ]
    return block
extractBlock (Image { imageWidth = w, imageHeight = h, imageData = src })
             block sampWidth sampHeight sampCount plane bx by = do
    let accessPixel x y | x < w && y < h = src !!! ((y * w + x) * sampCount + plane)
                        | x >= w = accessPixel (w - 1) y
                        | otherwise = accessPixel x (h - 1)

        pixelPerCoeff = fromIntegral $ sampWidth * sampCount

        blockVal x y = sum [fromIntegral $ accessPixel (blockXBegin + x + dx)   
                                                     (blockYBegin + y + dy)
                                | dy <- [0 .. sampHeight - 1]
                                , dx <- [0 .. sampWidth - 1] ] `div` pixelPerCoeff

        blockXBegin = bx * 8 * sampWidth
        blockYBegin = by * 8 * sampHeight

    sequence_ [(block .<-. (y * 8 + x)) $ blockVal x y | y <- [0 .. 7], x <- [0 .. 7] ]
    return block

serializeMacroBlock :: HuffmanWriterCode -> HuffmanWriterCode -> MutableMacroBlock s Int16
                    -> BoolWriter s ()
serializeMacroBlock dcCode _acCode _blk = do
    encodeInt dcCode 0

encodeMacroBlock :: QuantificationTable
                 -> MutableMacroBlock s Int16
                 -> ST s (MutableMacroBlock s Int16)
encodeMacroBlock quantTableOfComponent block = do
 workData <- M.new 64
 let inverseLevelShift = mutate (\_ v -> v - 128)
 -- inverse level shift
 inverseLevelShift block
        >>= fastDct workData
        >>= quantize quantTableOfComponent

divUpward :: (Integral a) => a -> a -> a
divUpward n dividor = val + (if rest /= 0 then 1 else 0)
    where (val, rest) = n `divMod` dividor

-- | Function to call to encode an image to jpeg
encodeJpeg :: Image PixelYCbCr8 -> Word8 -> B.ByteString
encodeJpeg img@(Image { imageWidth = w, imageHeight = h }) _quality = encode finalImage
  where finalImage = JpgImage [ JpgHuffmanTable huffTables
                              , JpgQuantTable quantTables
                              , JpgScans JpgBaselineDCTHuffman hdr
                              , JpgScanBlob scanHeader $ runPut encodedImage
                              ]

        huffTables = undefined

        outputComponentCount = 3

        scanHeader = JpgScanHeader
            { scanLength = fromIntegral $ calculateSize scanHeader
            , scanComponentCount = outputComponentCount
            , scans = []
            , spectralSelection = (0, 0) -- TODO find good values
            , successiveApproxHigh = 0   -- TODO find good values
            , successiveApproxLow  = 0   -- TODO find good values
            }
        hdr = (JpgFrameHeader { jpgFrameHeaderLength   = fromIntegral $ calculateSize hdr
                              , jpgSamplePrecision     = 0
                              , jpgHeight              = fromIntegral h
                              , jpgWidth               = fromIntegral w
                              , jpgImageComponentCount = outputComponentCount
                              , jpgComponents          = [
                                    JpgComponent { componentIdentifier      = 1
                                                 , horizontalSamplingFactor = 2
                                                 , verticalSamplingFactor   = 2
                                                 , quantizationTableDest    = 0
                                                 }
                                  , JpgComponent { componentIdentifier      = 2
                                                 , horizontalSamplingFactor = 1
                                                 , verticalSamplingFactor   = 1
                                                 , quantizationTableDest    = 1
                                                 }
                                  , JpgComponent { componentIdentifier      = 3
                                                 , horizontalSamplingFactor = 1
                                                 , verticalSamplingFactor   = 1
                                                 , quantizationTableDest    = 1
                                                 }
                                  ]
                              })

        quantTables = [ JpgQuantTableSpec { quantPrecision = 0, quantDestination = 0
                                          , quantTable = defaultLumaQuantizationTable }
                      , JpgQuantTableSpec { quantPrecision = 0, quantDestination = 1
                                          , quantTable = defaultChromaQuantizationTable }
                      ]

        (encodedImage, _, _) = runST toExtract
        toExtract = flip S.execStateT (return (), 0, 0) $ do
            let horizontalMetaBlockCount = w `divUpward` (8 * maxSampling)
                verticalMetaBlockCount = h `divUpward` (8 * maxSampling)
                maxSampling = 2
                lumaSamplingSize = ( maxSampling, maxSampling, defaultLumaQuantizationTable
                                   , makeInverseTable defaultDcLumaHuffmanTree
                                   , makeInverseTable defaultAcLumaHuffmanTree)
                chromaSamplingSize = ( maxSampling - 1, maxSampling - 1, defaultChromaQuantizationTable
                                     , makeInverseTable defaultDcChromaHuffmanTree
                                     , makeInverseTable defaultAcChromaHuffmanTree)
                componentDef = [lumaSamplingSize, chromaSamplingSize, chromaSamplingSize]
  
                imageComponentCount = length componentDef
            block <- lift $ M.new 64
            let blockList = [(table, dc, ac, extractBlock img block comp xSamplingFactor ySamplingFactor
                                                  imageComponentCount blockX blockY)
                                    | my <- [0 .. verticalMetaBlockCount - 1]
                                    , mx <- [0 .. horizontalMetaBlockCount - 1]
                                    , (comp, (sizeX, sizeY, table, dc, ac)) <- zip [0..] componentDef
                                    , subY <- [0 .. sizeY - 1]
                                    , subX <- [0 .. sizeX - 1]
                                    , let blockX = mx * sizeX + subX
                                          blockY = my * sizeY + subY
                                          xSamplingFactor = maxSampling - sizeX + 1
                                          ySamplingFactor = maxSampling - sizeY + 1
                                    ]
  
            forM_ blockList $ \(table, dc, ac, extractor) -> do
                lift (extractor >>= encodeMacroBlock table)
                    >>= serializeMacroBlock dc ac

