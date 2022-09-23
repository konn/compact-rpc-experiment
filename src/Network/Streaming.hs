{-# LANGUAGE NoMonomorphismRestriction #-}

module Network.Streaming (
  fromSocket,
  fromSocketWithBuf,
  toSocket,
) where

import Control.Monad (guard)
import Control.Monad.IO.Class (MonadIO (..))
import qualified Data.ByteString as BS
import Network.Socket (Socket)
import qualified Network.Socket.ByteString as BSSock
import qualified Streaming.ByteString as Q

fromSocket :: MonadIO m => Socket -> Q.ByteStream m ()
{-# INLINE fromSocket #-}
fromSocket = fromSocketWithBuf 4096

fromSocketWithBuf :: MonadIO m => Int -> Socket -> Q.ByteStream m ()
{-# INLINE fromSocketWithBuf #-}
fromSocketWithBuf nbytes = Q.reread $ \sock -> do
  bs <- liftIO $ BSSock.recv sock nbytes
  pure $ guard (not $ BS.null bs) >> Just bs

toSocket :: MonadIO m => Socket -> Q.ByteStream m r -> m r
{-# INLINE toSocket #-}
toSocket sock = Q.chunkMapM_ (liftIO . BSSock.send sock)
