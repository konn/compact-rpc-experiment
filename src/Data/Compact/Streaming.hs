{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Data.Compact.Streaming (
  -- * Helper data-types
  SomeCompact (..),
  SomeSerializedCompact (..),

  -- * Decoders
  decodeCompact,
  decodeCompacts,
  unsafeDecodeCompactWithoutTypecheck,
  unsafeDecodeCompactsWithoutTypecheck,
  decodeSomeCompact,
  decodeSomeCompacts,
  unsafeDecodeCompactWith,

  -- * Encoders
  encodeCompact,
  unsafeEncodeCompactWithoutType,

  -- * Low-level parsers and encoders

  -- ** Decoders
  getSomeSerializedCompact,
  getSerializedCompact,
  unsafeGetSerializedCompactWithoutTypecheck,

  -- ** Encoders
  formatCompactHeader,
  formatCompactBody,
) where

import qualified Control.Foldl as L
import Control.Monad (replicateM)
import Control.Monad.Trans.Reader (ReaderT (..))
import Data.Binary (Get)
import qualified Data.Binary as Bin
import qualified Data.Binary.Get as Get
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Internal as IBS
import qualified Data.ByteString.Unsafe as BS
import Data.Function
import Data.Functor.Of (Of (..))
import Data.Kind (Type)
import Data.Strict.Tuple (Pair (..))
import qualified Data.Strict.Tuple as STuple
import Data.Type.Equality (TestEquality (..), (:~:) (..), (:~~:) (..))
import Data.Word (Word64)
import Foreign (Ptr, castPtr, copyBytes, plusForeignPtr, plusPtr, ptrToWordPtr, withForeignPtr, wordPtrToPtr)
import GHC.Compact (Compact)
import GHC.Compact.Serialized (SerializedCompact (..), importCompact, withSerializedCompact)
import qualified Streaming.Binary as QB
import qualified Streaming.ByteString as Q
import qualified Streaming.Prelude as S
import Type.Reflection (SomeTypeRep (..), TypeRep, Typeable, eqTypeRep, typeRep, typeRepKind)
import UnliftIO (MonadIO (..), MonadUnliftIO, withRunInIO)
import UnliftIO.IORef

data SomeSerializedCompact where
  MkSomeSerializedCompact ::
    !(TypeRep (a :: Type)) ->
    !(SerializedCompact a) ->
    SomeSerializedCompact

data SomeCompact where
  MkSomeCompact :: !(TypeRep a) -> !(Compact a) -> SomeCompact

getSize :: Get Size
{-# INLINE getSize #-}
getSize = Get.getWord64be

getPtr :: Get (Ptr ())
{-# INLINE getPtr #-}
getPtr = fromWord64Addr <$> Get.getWord64be

getWord :: Get Word
getWord = fromIntegral <$> Get.getWord64be

decodeCompact ::
  forall a m r.
  (MonadUnliftIO m, Typeable a) =>
  Q.ByteStream m r ->
  m (Q.ByteStream m r, Either String (Compact a))
{-# INLINEABLE decodeCompact #-}
decodeCompact bs = do
  (lo, _, eith) <- QB.decodeWith getSerializedCompact bs
  case eith of
    Left str -> pure (lo, Left str)
    Right scompact -> unsafeDecodeCompactWith scompact lo

unsafeDecodeCompactWithoutTypecheck ::
  forall a m r.
  (MonadUnliftIO m) =>
  Q.ByteStream m r ->
  m (Q.ByteStream m r, Either String (Compact a))
{-# INLINEABLE unsafeDecodeCompactWithoutTypecheck #-}
unsafeDecodeCompactWithoutTypecheck bs = do
  (lo, _, eith) <- QB.decodeWith unsafeGetSerializedCompactWithoutTypecheck bs
  case eith of
    Left str -> pure (lo, Left str)
    Right scompact -> unsafeDecodeCompactWith scompact lo

decodeCompacts ::
  forall a m r.
  (MonadUnliftIO m, Typeable a) =>
  Q.ByteStream m r ->
  S.Stream (Of (Compact a)) m (Q.ByteStream m r, Either String r)
{-# INLINE decodeCompacts #-}
decodeCompacts = S.unfoldr $ \bs -> do
  (bs', eith) <- decodeCompact bs
  case eith of
    Left err -> pure $ Left (bs, Left err)
    Right cpt -> pure $ Right (cpt, bs')

unsafeDecodeCompactsWithoutTypecheck ::
  forall a m r.
  (MonadUnliftIO m) =>
  Q.ByteStream m r ->
  S.Stream (Of (Compact a)) m (Q.ByteStream m r, Either String r)
{-# INLINE unsafeDecodeCompactsWithoutTypecheck #-}
unsafeDecodeCompactsWithoutTypecheck = S.unfoldr $ \bs -> do
  (bs', eith) <- unsafeDecodeCompactWithoutTypecheck bs
  case eith of
    Left err -> pure $ Left (bs, Left err)
    Right cpt -> pure $ Right (cpt, bs')

decodeSomeCompact ::
  (MonadUnliftIO m) =>
  Q.ByteStream m r ->
  m (Q.ByteStream m r, Either String SomeCompact)
{-# INLINE decodeSomeCompact #-}
decodeSomeCompact bs = do
  (lo, _, eith) <- QB.decodeWith getSomeSerializedCompact bs
  case eith of
    Left str -> pure (lo, Left str)
    Right (MkSomeSerializedCompact rep scompact) ->
      fmap (fmap (MkSomeCompact rep)) <$> unsafeDecodeCompactWith scompact lo

decodeSomeCompacts ::
  (MonadUnliftIO m) =>
  Q.ByteStream m r ->
  S.Stream (Of SomeCompact) m (Q.ByteStream m r, Either String r)
{-# INLINE decodeSomeCompacts #-}
decodeSomeCompacts = S.unfoldr $ \bs -> do
  (bs', eith) <- decodeSomeCompact bs
  case eith of
    Left err -> pure $ Left (bs, Left err)
    Right cpt -> pure $ Right (cpt, bs')

unsafeDecodeCompactWith ::
  MonadUnliftIO m =>
  SerializedCompact a ->
  Q.ByteStream m r ->
  m (Q.ByteStream m r, Either String (Compact a))
unsafeDecodeCompactWith scompact lo = do
  -- sad, importCompact don't accept any accumulator...
  stRef <- newIORef lo
  liftIO $ putStrLn $ "To Decode " <> show (length $ serializedCompactBlockList scompact, serializedCompactBlockList scompact)
  cpt <- withRunInIO $ \unlift ->
    importCompact scompact $ \dest len -> do
      putStrLn $ "Deserialising to " <> show (dest, len)
      st <- readIORef stRef
      _ :> st' <-
        unlift $
          Q.splitAt (fromIntegral len) st
            & Q.toChunks
            & S.foldM
              -- Safe use; as the chunk will be copied by copyBytes.
              ( \ !off chunk -> liftIO $ do
                  BS.unsafeUseAsCStringLen chunk $ \(ptr, len) ->
                    copyBytes off ptr len
                  pure $! off `plusPtr` BS.length chunk
              )
              (pure dest)
              pure
      putStrLn "Stream folding done."
      writeIORef stRef st'
      putStrLn "Leftovr stream written to IORef"
  liftIO $ putStrLn "Compact import finished"
  lo' <- readIORef stRef
  liftIO $ putStrLn "readIORef final!"
  case cpt of
    Nothing -> do
      liftIO $ putStrLn "Reporting failure"
      pure (lo', Left "Compact deserialization failed; perhaps the data is corrupt?")
    Just a -> do
      liftIO $ putStrLn "Seems successed"
      pure (lo', Right a)

getSomeSerializedCompact :: Get SomeSerializedCompact
getSomeSerializedCompact = do
  SomeTypeRep rep <- Bin.get
  case testEquality (typeRepKind rep) (typeRep @Type) of
    Just Refl ->
      MkSomeSerializedCompact rep <$> unsafeGetSerializedCompactWithoutTypecheck
    Nothing -> fail "Serialised TypeRep was not of kind Type!"

getSerializedCompact :: forall a. Typeable a => Get (SerializedCompact a)
getSerializedCompact = do
  SomeTypeRep rep <- Bin.get
  case eqTypeRep rep (typeRep @a) of
    Just HRefl -> unsafeGetSerializedCompactWithoutTypecheck
    Nothing ->
      fail $
        "Type mismatched: (expected, got) = " <> show (typeRep @a, rep)

unsafeGetSerializedCompactWithoutTypecheck :: Get (SerializedCompact a)
{-# INLINE unsafeGetSerializedCompactWithoutTypecheck #-}
unsafeGetSerializedCompactWithoutTypecheck = do
  sz <- getSize
  serializedCompactBlockList <-
    replicateM (fromIntegral sz) $ (,) <$> getPtr <*> getWord
  serializedCompactRoot <- getPtr
  pure SerializedCompact {..}

formatCompactHeader :: SerializedCompact a -> BB.Builder
{-# INLINE formatCompactHeader #-}
formatCompactHeader (SerializedCompact blks hd) =
  L.fold
    ( fmap (STuple.uncurry (<>)) . (:!:)
        <$> (fmtSize <$> L.genericLength)
        <*> L.foldMap (\(ptr, len) -> fmtPtr ptr <> fmtWord len) id
    )
    blks
    <> BB.word64BE (ptrAddrInWord64 hd)

formatCompactBody :: SerializedCompact a -> IO [BS.ByteString]
{-# INLINE formatCompactBody #-}
formatCompactBody =
  mapM
    -- N.B. We cannot use 'unsafePackCStringLen' here;
    -- in that case, we might leak Ptr outside!
    (\(ptr, sz) -> BS.packCStringLen (castPtr ptr, fromIntegral sz))
    . serializedCompactBlockList

encodeCompact :: forall a m. (Typeable a, MonadIO m) => Compact a -> Q.ByteStream m ()
encodeCompact cpt = do
  QB.encode (SomeTypeRep $ typeRep @a)
  unsafeEncodeCompactWithoutType cpt

-- | Similar to 'encodeCompact' but doesn't emit type header.
unsafeEncodeCompactWithoutType :: forall a m. (MonadIO m) => Compact a -> Q.ByteStream m ()
unsafeEncodeCompactWithoutType cpt = do
  hdr :!: bdy <-
    liftIO $
      withSerializedCompact cpt $
        runReaderT $
          (:!:)
            <$> ReaderT (pure . formatCompactHeader)
            <*> ReaderT formatCompactBody
  Q.toStreamingByteString hdr
  Q.fromChunks $ S.each bdy

fmtWord :: Word -> BB.Builder
{-# INLINE fmtWord #-}
fmtWord = BB.word64BE . fromIntegral

fmtPtr :: Ptr () -> BB.Builder
{-# INLINE fmtPtr #-}
fmtPtr = BB.word64BE . ptrAddrInWord64

ptrAddrInWord64 :: Ptr () -> Word64
{-# INLINE ptrAddrInWord64 #-}
ptrAddrInWord64 = fromIntegral . ptrToWordPtr

fromWord64Addr :: Word64 -> Ptr ()
{-# INLINE fromWord64Addr #-}
fromWord64Addr = wordPtrToPtr . fromIntegral

type Size = Word64

fmtSize :: Size -> BB.Builder
{-# INLINE fmtSize #-}
fmtSize = BB.word64BE
