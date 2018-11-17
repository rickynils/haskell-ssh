{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RankNTypes                #-}
module Network.SSH.Client.Connection where

import           Control.Applicative
import           Control.Concurrent.Async              ( Async (..), link, async, withAsync, waitSTM )
import           Control.Concurrent.STM.TVar
import           Control.Concurrent.STM.TMVar
import           Control.Exception                     ( Exception, throwIO )
import           Control.Monad
import           Control.Monad.STM
import           Data.Default
import           Data.Function                         ( fix )
import           Data.List                             ( intersect )
import           Data.Map.Strict                       as M
import           System.Exit
import           Data.Word
import qualified Data.ByteString                       as BS
import qualified Data.ByteString.Short                 as SBS

import           Network.SSH.Constants
import           Network.SSH.Exception
import           Network.SSH.Encoding
import           Network.SSH.Message
import           Network.SSH.Key
import           Network.SSH.Name
import           Network.SSH.Stream
import           Network.SSH.Transport
import qualified Network.SSH.Builder                   as B
import qualified Network.SSH.TStreamingQueue           as Q

data ConnectionConfig
    = ConnectionConfig
    { channelMaxCount       :: Word16
      -- ^ The maximum number of channels that may be active simultaneously (default: 256).
    , channelMaxQueueSize   :: Word32
      -- ^ The maximum size of the internal buffers in bytes (also
      --   limits the maximum window size, default: 32 kB)
      --
      --   Increasing this value might help with performance issues
      --   (if connection delay is in a bad ration with the available bandwidth the window
      --   resizing might cause unncessary throttling).
    , channelMaxPacketSize  :: Word32
      -- ^ The maximum size of inbound channel data payload (default: 32 kB)
      --
      --   Values that are larger than `channelMaxQueueSize` or the
      --   maximum message size (35000 bytes) will be automatically adjusted
      --   to the maximum possible value.
    }

instance Default ConnectionConfig where
    def = ConnectionConfig
        { channelMaxCount      = 256
        , channelMaxQueueSize  = 32 * 1024
        , channelMaxPacketSize = 32 * 1024
        }

data Connection
    = Connection
    { connConfig    :: ConnectionConfig
    , connOutbound  :: TMVar OutboundMessage
    , connChannels  :: TVar (M.Map ChannelId ChannelState)
    }

data ChannelState
    = ChannelOpening (Either ChannelOpenFailure ChannelOpenConfirmation -> STM ())
    | ChannelRunning Channel
    | ChannelClosing

data Channel
    = Channel 
    { chanIdLocal             :: ChannelId
    , chanIdRemote            :: ChannelId
    , chanMaxPacketSizeLocal  :: Word32
    , chanMaxPacketSizeRemote :: Word32
    , chanWindowSizeLocal     :: TVar Word32
    , chanWindowSizeRemote    :: TVar Word32
    , chanThread              :: TMVar (Async ())
    , chanApplication         :: ChannelApplication
    }

data ChannelApplication
    = ChannelApplicationSession ChannelSession

data ChannelSession
    = ChannelSession
    { sessStdin       :: Q.TStreamingQueue
    , sessStdout      :: Q.TStreamingQueue
    , sessStderr      :: Q.TStreamingQueue
    }

newtype Command = Command BS.ByteString

data InboundMessage
    = I080 GlobalRequest
    | I091 ChannelOpenConfirmation
    | I092 ChannelOpenFailure
    | I093 ChannelWindowAdjust
    | I094 ChannelData
    | I095 ChannelExtendedData
    | I096 ChannelEof
    | I097 ChannelClose
    | I098 ChannelRequest
    | I099 ChannelSuccess
    | I100 ChannelFailure

instance Decoding InboundMessage where
    get   = I080 <$> get
        <|> I091 <$> get
        <|> I092 <$> get
        <|> I093 <$> get
        <|> I094 <$> get
        <|> I095 <$> get
        <|> I096 <$> get
        <|> I097 <$> get
        <|> I098 <$> get
        <|> I099 <$> get
        <|> I100 <$> get

data OutboundMessage
    = O90 ChannelOpen
    | O93 ChannelWindowAdjust
    | O94 ChannelData
    | O96 ChannelEof
    | O97 ChannelClose
    | O98 ChannelRequest

instance Encoding OutboundMessage where
    put (O90 x) = put x
    put (O93 x) = put x
    put (O94 x) = put x
    put (O96 x) = put x
    put (O97 x) = put x
    put (O98 x) = put x

data ChannelException
    = ChannelOpenFailed ChannelOpenFailureReason ChannelOpenFailureDescription
    deriving (Eq, Show)

instance Exception ChannelException where

newtype ChannelOpenFailureDescription = ChannelOpenFailureDescription BS.ByteString
    deriving (Eq, Ord, Show)

newtype Environment = Environment ()

newtype ExecHandler a = ExecHandler (forall stdin stdout stderr. (OutputStream stdin, InputStream stdout, InputStream stderr)
    => stdin -> stdout -> stderr -> IO a)

sendOutbound :: Connection -> OutboundMessage -> IO ()
sendOutbound c = atomically . putTMVar (connOutbound c)

withConnection :: (MessageStream stream) => ConnectionConfig -> stream -> (Connection -> IO a) -> IO a
withConnection config stream handler = do
    c <- atomically $ Connection config <$> newEmptyTMVar <*> newTVar mempty
    withAsync (dispatchIncoming stream c) $ \receiverThread -> do
        link receiverThread -- FIXME
        withAsync (handler c) $ \handlerThread -> fix $ \continue -> do
            let left  = Left  <$> takeTMVar (connOutbound c)
                right = Right <$> waitSTM handlerThread
            atomically (left <|> right) >>= \case
                Left msg -> sendMessage stream msg >> continue
                Right a  -> pure a
    where
        dispatchIncoming :: (MessageStream stream) => stream -> Connection -> IO ()
        dispatchIncoming s c = forever $ receiveMessage s >>= \case
            I080 x -> print x -- FIXME
            I091 x@(ChannelOpenConfirmation lid _ _ _) -> atomically $ do
                getChannelStateSTM c lid >>= \case
                    ChannelOpening f  -> f (Right x)
                    _                 -> throwSTM exceptionInvalidChannelState
            I092 x@(ChannelOpenFailure lid _ _ _) -> atomically $ do
                getChannelStateSTM c lid >>= \case
                    ChannelOpening f  -> f (Left x)
                    _                 -> throwSTM exceptionInvalidChannelState
            I093 (ChannelWindowAdjust lid size) -> atomically $ do
                getChannelStateSTM c lid >>= \case
                    ChannelOpening {} -> throwSTM exceptionInvalidChannelState
                    ChannelRunning ch -> channelAdjustWindowSTM ch size
                    ChannelClosing {} -> pure ()
            I094 (ChannelData lid dat) -> atomically $ do
                getChannelStateSTM c lid >>= \case
                    ChannelOpening {} -> throwSTM exceptionInvalidChannelState
                    ChannelRunning ch -> channelDataSTM ch dat
                    ChannelClosing {} -> pure ()
            I095  (ChannelExtendedData lid typ dat) -> atomically $ do
                getChannelStateSTM c lid >>= \case
                    ChannelOpening {} -> throwSTM exceptionInvalidChannelState
                    ChannelRunning ch -> channelExtendedDataSTM ch typ dat
                    ChannelClosing {} -> pure ()
            I096 (ChannelEof lid) -> atomically $ do
                getChannelStateSTM c lid >>= \case
                    ChannelOpening {} -> throwSTM exceptionInvalidChannelState
                    ChannelRunning ch -> channelEofSTM ch
                    ChannelClosing {} -> pure ()
            I097 (ChannelClose lid) -> do
                atomically $ getChannelStateSTM c lid >>= \case
                    ChannelOpening {} -> throwSTM exceptionInvalidChannelState
                    ChannelRunning {} -> freeChannelSTM c lid
                    ChannelClosing {} -> freeChannelSTM c lid
            I098  x -> print x
            I099  x -> print x
            I100  x -> print x

exec :: Connection -> Command -> ExecHandler a -> IO a
exec c cmd (ExecHandler handler) = do
    tlws    <- newTVarIO maxQueueSize
    trws    <- newTVarIO 0
    stdin   <- atomically (Q.newTStreamingQueue maxQueueSize trws)
    stdout  <- atomically (Q.newTStreamingQueue maxQueueSize tlws)
    stderr  <- atomically (Q.newTStreamingQueue maxQueueSize tlws)
    r       <- newEmptyTMVarIO
    lid     <- atomically $ openChannelSTM c $ \case
        Left x@ChannelOpenFailure {} -> do
            putTMVar r (Left x)
        Right (ChannelOpenConfirmation lid rid rws rps) -> do
            let session = ChannelSession
                    { sessStdin               = stdin
                    , sessStdout              = stdout
                    , sessStderr              = stderr
                    }
            let channel = Channel
                    { chanIdLocal             = lid
                    , chanIdRemote            = rid
                    , chanMaxPacketSizeLocal  = maxPacketSize
                    , chanMaxPacketSizeRemote = rps
                    , chanWindowSizeLocal     = tlws
                    , chanWindowSizeRemote    = trws
                    , chanApplication         = ChannelApplicationSession session
                    }
            writeTVar trws rws
            setChannelStateSTM c lid $ ChannelRunning channel
            putTMVar r (Right channel)
    sendOutbound c $ O90 $ ChannelOpen lid maxQueueSize maxPacketSize ChannelOpenSession
    atomically (readTMVar r) >>= \case
        Left (ChannelOpenFailure _ reason descr _) -> throwIO
            $ ChannelOpenFailed reason
            $ ChannelOpenFailureDescription $ SBS.fromShort descr
        Right ch -> do
            sendOutbound c $ O98 $ ChannelRequest
                { crChannel   = chanIdRemote ch
                , crType      = "exec"
                , crWantReply = True
                , crData      = runPut (put $ ChannelRequestExec "ls")
                }
            handler stdin stdout stderr
    where
        -- The maxQueueSize must at least be one (even if 0 in the config)
        -- and lower than range of Int (might happen on 32bit systems
        -- as Int's guaranteed upper bound is only 2^29 -1).
        -- The value is adjusted silently as this won't be a problem
        -- for real use cases and is just the safest thing to do.
        maxQueueSize :: Word32
        maxQueueSize = max 1 $ fromIntegral $ min maxBoundIntWord32
            (channelMaxQueueSize $ connConfig c)

        maxPacketSize :: Word32
        maxPacketSize = max 1 $ fromIntegral $ min maxBoundIntWord32
            (channelMaxPacketSize $ connConfig c)

openChannelSTM ::
    Connection ->
    (Either ChannelOpenFailure ChannelOpenConfirmation -> STM ()) ->
    STM ChannelId
openChannelSTM c handler = do
    channels <- readTVar (connChannels c)
    case findSlot channels of
        Nothing -> retry
        Just i  -> do
            setChannelStateSTM c i (ChannelOpening handler)
            pure i
    where
        findSlot :: M.Map ChannelId a -> Maybe ChannelId
        findSlot m
            | M.size m >= fromIntegral maxCount = Nothing
            | otherwise = f (ChannelId 0) $ M.keys m
            where
                f i []          = Just i
                f (ChannelId i) (ChannelId k:ks)
                    | i == k    = f (ChannelId $ i+1) ks
                    | otherwise = Just (ChannelId i)
                maxCount = channelMaxCount (connConfig c)

freeChannelSTM :: Connection -> ChannelId -> STM ()
freeChannelSTM c lid = do
    channels <- readTVar (connChannels c)
    writeTVar (connChannels c) $! M.delete lid channels

getChannelStateSTM :: Connection -> ChannelId -> STM ChannelState
getChannelStateSTM c lid = do
    channels <- readTVar (connChannels c)
    maybe (throwSTM exceptionInvalidChannelId) pure (M.lookup lid channels)

setChannelStateSTM :: Connection -> ChannelId -> ChannelState -> STM ()
setChannelStateSTM c lid st = do
    channels <- readTVar (connChannels c)
    writeTVar (connChannels c) $! M.insert lid st channels

channelAdjustWindowSTM :: Channel -> Word32 -> STM ()
channelAdjustWindowSTM ch increment = case chanApplication ch of
    ChannelApplicationSession ChannelSession { sessStdin = queue } ->
        Q.addWindowSpace queue increment <|> throwSTM exceptionWindowSizeOverflow

channelDataSTM :: Channel -> SBS.ShortByteString -> STM ()
channelDataSTM ch datShort = case chanApplication ch of
    ChannelApplicationSession ChannelSession { sessStdout = queue } -> do
        enqueued <- Q.enqueue queue dat <|> pure 0
        when (enqueued /= len) (throwSTM exceptionWindowSizeUnderrun)
    where
        dat = SBS.fromShort datShort
        len = fromIntegral (SBS.length datShort)

channelExtendedDataSTM :: Channel -> Word32 -> SBS.ShortByteString -> STM ()
channelExtendedDataSTM ch _ datShort = case chanApplication ch of
    ChannelApplicationSession ChannelSession { sessStderr = queue } -> do
        enqueued <- Q.enqueue queue dat <|> pure 0
        when (enqueued /= len) (throwSTM exceptionWindowSizeUnderrun)
    where
        dat = SBS.fromShort datShort
        len = fromIntegral (SBS.length datShort)

channelEofSTM :: Channel -> STM ()
channelEofSTM ch = case chanApplication ch of
    ChannelApplicationSession ChannelSession { sessStdout = out, sessStderr = err } -> do
        Q.terminate out
        Q.terminate err
