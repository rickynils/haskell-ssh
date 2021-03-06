{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE MultiWayIf                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Network.SSH.Server.Connection
    ( Connection ()
    , ConnectionConfig (..)
    , SessionRequest (..)
    , SessionHandler (..)
    , DirectTcpIpRequest (..)
    , DirectTcpIpHandler (..)
    , ConnectionMsg (..)
    , serveConnection
    ) where

import           Control.Applicative
import qualified Control.Concurrent.Async     as Async
import           Control.Concurrent.STM.TVar
import           Control.Concurrent.STM.TMVar
import           Control.Monad                (join, when, forever, unless)
import           Control.Monad.STM            (STM, atomically, check, throwSTM)
import           Control.Exception            (bracket, bracketOnError, onException, throwIO)
import qualified Data.ByteString              as BS
import qualified Data.ByteString.Short        as SBS
import           Data.Default
import qualified Data.Map.Strict              as M
import qualified Data.Set                     as Set
import           Data.Word
import           System.Exit

import           Network.SSH.Encoding
import           Network.SSH.Environment
import           Network.SSH.Exception
import           Network.SSH.Constants
import           Network.SSH.HostAddress
import           Network.SSH.Message
import qualified Network.SSH.Stream as S
import           Network.SSH.Server.Switchboard
import           Network.SSH.TermInfo
import qualified Network.SSH.TWindowBuffer as B

data ConnectionConfig identity
    = ConnectionConfig
    { onSessionRequest      :: identity -> SessionRequest -> IO (Maybe SessionHandler)
      -- ^ This callback will be executed for every session request.
      --
      --   Return a `SessionHandler` or `Nothing` to reject the request (default).
    , onDirectTcpIpRequest  :: identity -> DirectTcpIpRequest -> IO (Maybe DirectTcpIpHandler)
      -- ^ This callback will be executed for every direct-tcpip request.
      --
      --   Return a `DirectTcpIpHandler` or `Nothing` to reject the request (default).
    , channelMaxCount       :: Word16
      -- ^ The maximum number of channels that may be active simultaneously (default: 256).
      --
      --   Any requests that would exceed the limit will be rejected.
      --   Setting the limit to high values might expose the server to denial
      --   of service issues!
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
    , switchboard           :: Maybe Switchboard
    }

instance Default (ConnectionConfig identity) where
    def = ConnectionConfig
        { onSessionRequest              = \_ _ -> pure Nothing
        , onDirectTcpIpRequest          = \_ _ -> pure Nothing
        , channelMaxCount               = 256
        , channelMaxQueueSize           = 32 * 1024
        , channelMaxPacketSize          = 32 * 1024
        , switchboard                   = Nothing
        }

-- | Information associated with the session request.
--
--   Might be exteded in the future.
data SessionRequest
    = SessionRequest
    deriving (Eq, Ord, Show)

-- | The session handler contains the application logic that serves a client's
--   shell or exec request.
--
--   * The `Command` parameter will be present if this is an exec request and absent
--     for shell requests.
--   * The `TermInfo` parameter will be present if the client requested a pty.
--   * The `Environment` parameter contains the set of all env requests
--     the client issued before the actual shell or exec request.
--   * @stdin@, @stdout@ and @stderr@ are streams. The former can only be read
--     from while the latter can only be written to.
--     After the handler has gracefully terminated, the implementation assures
--     that all bytes will be sent before sending an eof and actually closing the
--     channel.
--     has gracefully terminated. The client will then receive an eof and close.
--   * A @SIGILL@ exit signal will be sent if the handler terminates with an exception.
--     Otherwise the client will receive the returned exit code.
--
-- @
-- handler :: SessionHandler
-- handler = SessionHandler $ \\env mterm mcmd stdin stdout stderr -> case mcmd of
--     Just "echo" -> do
--         bs <- `receive` stdin 1024
--         `sendAll` stdout bs
--         pure `ExitSuccess`
--     Nothing ->
--         pure (`ExitFailure` 1)
-- @
newtype SessionHandler =
    SessionHandler (forall stdin stdout stderr. (S.InputStream stdin, S.OutputStream stdout, S.OutputStream stderr)
        => Environment -> Maybe TermInfo -> Maybe Command -> stdin -> stdout -> stderr -> IO ExitCode)

-- | When the client makes a `DirectTcpIpRequest` it requests a TCP port forwarding.
data DirectTcpIpRequest
    = DirectTcpIpRequest
    { dstAddress   :: BS.ByteString
    -- ^ The destination address.
    , dstPort      :: Word32
    -- ^ The destination port.
    , srcAddress   :: BS.ByteString
    -- ^ The source address (usually the IP the client will bind the local listening socket to).
    , srcPort      :: Word32
    -- ^ The source port (usually the port the client will bind the local listening socket).
    } deriving (Eq, Ord, Show)

-- | The `DirectTcpIpHandler` contains the application logic
--   that handles port forwarding requests.
--
--   There is of course no need to actually do a real forwarding - this
--   mechanism might also be used to give access to process internal services
--   like integrated web servers etc.
--
--   * When the handler exits gracefully, the implementation assures that
--     all bytes will be sent to the client before terminating the stream
--     with an eof and actually closing the channel.
newtype DirectTcpIpHandler =
    DirectTcpIpHandler (forall stream. S.DuplexStream stream => stream -> IO ())

data Connection identity
    = Connection
    { connConfig       :: ConnectionConfig identity
    , connIdentity     :: identity
    , connChannels     :: TVar (M.Map ChannelId ChannelState)
    , connForwardings  :: TVar (Set.Set HostAddress) -- FIXME: free on exit
    }

data ChannelState
    = ChannelOpening (Either ChannelOpenFailure ChannelOpenConfirmation -> STM ())
    | ChannelRunning Channel
    | ChannelClosing

data Channel
    = Channel
    { chanApplication         :: ChannelApplication
    , chanIdLocal             :: ChannelId
    , chanIdRemote            :: ChannelId
    , chanWindowSizeLocal     :: TVar Word32
    , chanWindowSizeRemote    :: TVar Word32
    , chanMaxPacketSizeRemote :: Word32
    , chanClosed              :: TVar Bool
    , chanThread              :: TMVar (Async.Async ())
    }

data ChannelApplication
    = ChannelApplicationSession SessionState
    | ChannelApplicationDirectTcpIp DirectTcpIpState
    | ChannelApplicationForwardedTcpIp ForwardedTcpIpState

data SessionState
    = SessionState
    { sessHandler     :: SessionHandler
    , sessEnvironment :: TVar Environment
    , sessPtySettings :: TVar (Maybe PtySettings)
    , sessStdin       :: B.TWindowBuffer
    , sessStdout      :: B.TWindowBuffer
    , sessStderr      :: B.TWindowBuffer
    }

data DirectTcpIpState
    = DirectTcpIpState
    { dtiStreamIn     :: B.TWindowBuffer
    , dtiStreamOut    :: B.TWindowBuffer
    }

data ForwardedTcpIpState
    = ForwardedTcpIpState
    { ftiStreamIn     :: B.TWindowBuffer
    , ftiStreamOut    :: B.TWindowBuffer
    }

instance S.InputStream DirectTcpIpState where
    peek x = S.peek (dtiStreamIn x)
    receive x = S.receive (dtiStreamIn x)

instance S.OutputStream DirectTcpIpState where
    send x = S.send (dtiStreamOut x)

instance S.DuplexStream DirectTcpIpState where

instance S.InputStream ForwardedTcpIpState where
    peek x = S.peek (ftiStreamIn x)
    receive x = S.receive (ftiStreamIn x)

instance S.OutputStream ForwardedTcpIpState where
    send x = S.send (ftiStreamOut x)

instance S.DuplexStream ForwardedTcpIpState where

data ConnectionMsg
    = ConnectionGlobalRequest       GlobalRequest
    | ConnectionChannelOpen         ChannelOpen
    | ConnectionChannelClose        ChannelClose
    | ConnectionChannelEof          ChannelEof
    | ConnectionChannelData         ChannelData
    | ConnectionChannelRequest      ChannelRequest
    | ConnectionChannelWindowAdjust ChannelWindowAdjust
    deriving (Eq, Show)

instance Decoding ConnectionMsg where
    get =   (ConnectionGlobalRequest       <$> get)
        <|> (ConnectionChannelOpen         <$> get)
        <|> (ConnectionChannelClose        <$> get)
        <|> (ConnectionChannelEof          <$> get)
        <|> (ConnectionChannelData         <$> get)
        <|> (ConnectionChannelRequest      <$> get)
        <|> (ConnectionChannelWindowAdjust <$> get)

serveConnection :: forall stream identity. MessageStream stream =>
    ConnectionConfig identity -> stream -> identity -> IO ()
serveConnection config stream idnt = bracket open close $ \connection ->
    forever $ receiveMessage stream >>= \case
        ConnectionGlobalRequest       req -> connectionGlobalRequest       connection stream req
        ConnectionChannelOpen         req -> connectionChannelOpen         connection stream req
        ConnectionChannelClose        req -> connectionChannelClose        connection stream req
        ConnectionChannelEof          req -> connectionChannelEof          connection        req
        ConnectionChannelData         req -> connectionChannelData         connection        req
        ConnectionChannelRequest      req -> connectionChannelRequest      connection stream req
        ConnectionChannelWindowAdjust req -> connectionChannelWindowAdjust connection        req
    where
        open :: IO (Connection identity)
        open = Connection
            <$> pure config
            <*> pure idnt
            <*> newTVarIO mempty
            <*> newTVarIO mempty

        close :: Connection identity -> IO ()
        close connection = do
            channels <- readTVarIO (connChannels connection)
            mapM_ terminate (M.elems channels)
            where
                terminate = \case
                    ChannelOpening {} -> undefined -- FIXME
                    ChannelRunning ch -> maybe (pure ()) Async.cancel =<< atomically (tryReadTMVar $ chanThread ch)
                    ChannelClosing    -> pure ()

openForwardedChannel :: MessageStream stream => Connection identity -> stream -> HostAddress -> HostAddress -> IO (Maybe ForwardedTcpIpState)
openForwardedChannel conn stream bindAddr origAddr = do
    let lws = maxBufferSize
        lps = maxPacketSize
    tSt <- newEmptyTMVarIO
    mLid <- atomically do
        channels <- readTVar (connChannels conn)
        case selectFreeLocalChannelId conn channels of
            Nothing  -> pure Nothing
            Just lid -> do
                insertChannelSTM conn lid $ ChannelOpening $ \case
                    Left (ChannelOpenFailure {}) -> do
                        deleteChannelSTM conn lid
                        putTMVar tSt $ Left ()
                    Right (ChannelOpenConfirmation _ rid rws rps) -> do
                        tLws    <- newTVar lws
                        tRws    <- newTVar rws
                        tClosed <- newTVar False
                        tThread <- newEmptyTMVar
                        st      <- ForwardedTcpIpState
                                    <$> B.newTWindowBufferSTM maxBufferSize tLws
                                    <*> B.newTWindowBufferSTM maxBufferSize tRws
                        let ch = Channel
                                { chanApplication         = ChannelApplicationForwardedTcpIp st
                                , chanIdLocal             = lid
                                , chanIdRemote            = rid
                                , chanWindowSizeLocal     = tLws
                                , chanWindowSizeRemote    = tRws
                                , chanMaxPacketSizeRemote = rps
                                , chanClosed              = tClosed
                                , chanThread              = tThread
                                }
                        insertChannelSTM conn lid $ ChannelRunning ch
                        putTMVar tSt $ Right (ch,st)
                pure (Just lid)
    case mLid of
        Nothing -> undefined -- FIXME
        Just lid -> do
            sendMessage stream
                $ ChannelOpen lid lws lps
                $ ChannelOpenForwardedTcpIp
                    { coConnected   = bindAddr
                    , coOrigin      = origAddr
                    } 
            atomically (readTMVar tSt) >>= \case
                Left {} ->
                    undefined -- FIXME
                Right (ch,st) ->
                    pure (Just st)
    where
        maxBufferSize :: Word32
        maxBufferSize = max 1 $ fromIntegral $ min maxBoundIntWord32
            (channelMaxQueueSize $ connConfig conn)

        maxPacketSize :: Word32
        maxPacketSize = max 1 $ fromIntegral $ min maxBoundIntWord32
            (channelMaxPacketSize $ connConfig conn)

connectionGlobalRequest :: MessageStream stream => Connection identity -> stream -> GlobalRequest -> IO ()
connectionGlobalRequest connection stream (GlobalRequest wantReply tp) = case tp of
    GlobalRequestOther {} -> failure
    GlobalRequestTcpIpForward bindAddr -> case switchboard (connConfig connection) of
        Nothing -> failure
        Just sb -> do
            let connect = openForwardedChannel connection stream bindAddr
            let register = requestForwarding sb "FIXME" bindAddr connect >>= \case
                    False -> failure
                    True  -> success >> addForwarding bindAddr
            let unregister = do
                    cancelForwarding sb "FIXME" bindAddr
                    delForwarding bindAddr
            -- Catching the exception is only relevant for the very
            -- unlikely case that the connection gets closed right after
            -- external registration but before local registration.
            register `onException` unregister
    where
        failure = when wantReply (sendMessage stream RequestFailure)
        success = when wantReply (sendMessage stream RequestSuccess)
        -- The forwarding needs to registered locally as well as it needs to be
        -- removed from the switchboard when the connection is closed.
        addForwarding bindAddr = atomically do
            fwds <- readTVar (connForwardings connection)
            writeTVar (connForwardings connection) $! Set.insert bindAddr fwds
        delForwarding bindAddr = atomically do
            fwds <- readTVar (connForwardings connection)
            writeTVar (connForwardings connection) $! Set.delete bindAddr fwds

connectionChannelOpen :: forall stream identity. MessageStream stream =>
    Connection identity -> stream -> ChannelOpen -> IO ()
connectionChannelOpen connection stream (ChannelOpen remoteChannelId remoteWindowSize remotePacketSize channelType) =
    case channelType of
        ChannelOpenSession ->
            onSessionRequest (connConfig connection) (connIdentity connection) SessionRequest >>= \case
                Nothing ->
                    sendMessage stream $ openFailure ChannelOpenAdministrativelyProhibited
                Just handler -> do
                    env      <- newTVarIO (Environment [])
                    pty      <- newTVarIO Nothing
                    wsLocal  <- newTVarIO maxQueueSize
                    wsRemote <- newTVarIO remoteWindowSize
                    stdIn    <- atomically $ B.newTWindowBufferSTM maxQueueSize wsLocal
                    stdOut   <- atomically $ B.newTWindowBufferSTM maxQueueSize wsRemote
                    stdErr   <- atomically $ B.newTWindowBufferSTM maxQueueSize wsRemote
                    let app = ChannelApplicationSession SessionState
                            { sessHandler     = handler
                            , sessEnvironment = env
                            , sessPtySettings = pty
                            , sessStdin       = stdIn
                            , sessStdout      = stdOut
                            , sessStderr      = stdErr
                            }
                    atomically (openApplicationChannel wsLocal wsRemote app) >>= \case
                        Left failure           -> sendMessage stream failure
                        Right (_,confirmation) -> sendMessage stream confirmation
        ChannelOpenDirectTcpIp da dp oa op -> do
            let req = DirectTcpIpRequest (SBS.fromShort da) dp (SBS.fromShort oa) op
            onDirectTcpIpRequest (connConfig connection) (connIdentity connection) req >>= \case
                Nothing ->
                    sendMessage stream $ openFailure ChannelOpenAdministrativelyProhibited
                Just (DirectTcpIpHandler handler) -> do
                    wsLocal   <- newTVarIO maxQueueSize
                    wsRemote  <- newTVarIO remoteWindowSize
                    streamIn  <- atomically $ B.newTWindowBufferSTM maxQueueSize wsLocal
                    streamOut <- atomically $ B.newTWindowBufferSTM maxQueueSize wsRemote
                    let st = DirectTcpIpState
                            { dtiStreamIn  = streamIn
                            , dtiStreamOut = streamOut
                            }
                    let app = ChannelApplicationDirectTcpIp st
                    atomically (openApplicationChannel wsLocal wsRemote app) >>= \case
                        Left failure -> sendMessage stream failure
                        Right (c,confirmation) -> do
                            forkDirectTcpIpHandler stream c st (handler st)
                            sendMessage stream confirmation
        ChannelOpenOther {} ->
            sendMessage stream $ openFailure ChannelOpenUnknownChannelType
    where
        openFailure :: ChannelOpenFailureReason -> ChannelOpenFailure
        openFailure reason = ChannelOpenFailure remoteChannelId reason mempty mempty

        openApplicationChannel ::
            TVar Word32 -> TVar Word32 -> ChannelApplication
             -> STM (Either ChannelOpenFailure (Channel, ChannelOpenConfirmation))
        openApplicationChannel wsLocal wsRemote application = tryRegisterChannel $ \localChannelId -> do
            closed <- newTVar False
            thread <- newEmptyTMVar
            pure Channel
                { chanApplication         = application
                , chanIdLocal             = localChannelId
                , chanIdRemote            = remoteChannelId
                , chanWindowSizeLocal     = wsLocal
                , chanWindowSizeRemote    = wsRemote
                , chanMaxPacketSizeRemote = remotePacketSize
                , chanClosed              = closed
                , chanThread              = thread
                }

        tryRegisterChannel :: (ChannelId -> STM Channel) -> STM (Either ChannelOpenFailure (Channel, ChannelOpenConfirmation))
        tryRegisterChannel createChannel = do
            channels <- readTVar (connChannels connection)
            case selectFreeLocalChannelId connection channels of
                Nothing ->
                    pure $ Left $ openFailure ChannelOpenResourceShortage
                Just localChannelId -> do
                    channel <- createChannel localChannelId
                    writeTVar (connChannels connection) $!
                        M.insert localChannelId (ChannelRunning channel) channels
                    pure $ Right $ (channel,) $ ChannelOpenConfirmation
                        remoteChannelId
                        localChannelId
                        maxQueueSize
                        maxPacketSize

        -- The maxQueueSize must at least be one (even if 0 in the config)
        -- and must not exceed the range of Int (might happen on 32bit systems
        -- as Int's guaranteed upper bound is only 2^29 -1).
        -- The value is adjusted silently as this won't be a problem
        -- for real use cases and is just the safest thing to do.
        maxQueueSize :: Word32
        maxQueueSize = max 1 $ fromIntegral $ min maxBoundIntWord32
            (channelMaxQueueSize $ connConfig connection)

        maxPacketSize :: Word32
        maxPacketSize = max 1 $ fromIntegral $ min maxBoundIntWord32
            (channelMaxPacketSize $ connConfig connection)

connectionChannelEof ::
    Connection identity -> ChannelEof -> IO ()
connectionChannelEof connection (ChannelEof localChannelId) =
    atomically $ getChannelSTM connection localChannelId >>= \case
        ChannelOpening {} -> throwSTM exceptionInvalidChannelState -- FIXME
        ChannelClosing    -> pure () -- FIXME
        ChannelRunning ch -> do
            let queue = case chanApplication ch of
                    ChannelApplicationSession     st -> sessStdin   st
                    ChannelApplicationDirectTcpIp st -> dtiStreamIn st
            S.sendEofSTM queue

connectionChannelClose :: forall stream identity. MessageStream stream =>
    Connection identity -> stream -> ChannelClose -> IO ()
connectionChannelClose connection stream (ChannelClose localChannelId) = do
    atomically (getChannelSTM connection localChannelId) >>= \case
        ChannelOpening {} -> throwIO exceptionInvalidChannelState -- FIXME
        ChannelClosing    -> pure () -- FIXME
        ChannelRunning ch -> do
            maybe (pure ()) Async.cancel =<< atomically (tryReadTMVar $ chanThread ch)
            atomically do
                channels <- readTVar (connChannels connection)
                writeTVar (connChannels connection) $! M.delete localChannelId channels
            -- When the channel is not marked as already closed then the close
            -- must have been initiated by the client and the server needs to send
            -- a confirmation (both sides may issue close messages simultaneously
            -- and receive them afterwards).
            closeAlreadySent <- readTVarIO (chanClosed ch)
            unless closeAlreadySent $
                sendMessage stream $ ChannelClose $ chanIdRemote ch

connectionChannelData ::
    Connection identity -> ChannelData -> IO ()
connectionChannelData connection (ChannelData localChannelId packet) =
    atomically $ getChannelSTM connection localChannelId >>= \case
        ChannelOpening {} -> throwSTM exceptionInvalidChannelState
        ChannelClosing    -> pure () -- FIXME
        ChannelRunning channel -> do
            when (packetSize > maxPacketSize) (throwSTM exceptionPacketSizeExceeded)
            let queue = case chanApplication channel of
                    ChannelApplicationSession     st -> sessStdin   st
                    ChannelApplicationDirectTcpIp st -> dtiStreamIn st
            eof <- B.askEofSTM queue
            when eof (throwSTM exceptionDataAfterEof)
            i <- B.enqueueShortSTM queue packet <|> throwSTM exceptionWindowSizeUnderrun
            when (i /= packetSize) (throwSTM exceptionWindowSizeUnderrun)
    where
        packetSize :: Word32
        packetSize = fromIntegral $ SBS.length packet

        maxPacketSize :: Word32
        maxPacketSize = max 1 $ fromIntegral $ min maxBoundIntWord32
            (channelMaxPacketSize $ connConfig connection)

connectionChannelWindowAdjust ::
    Connection identity -> ChannelWindowAdjust -> IO ()
connectionChannelWindowAdjust connection (ChannelWindowAdjust channelId increment) =
    atomically $ getChannelSTM connection channelId >>= \case
        ChannelOpening {} -> throwSTM exceptionInvalidChannelState
        ChannelClosing    -> pure () -- FIXME
        ChannelRunning channel -> do
            window <- readTVar (chanWindowSizeRemote channel)
            unless ((fromIntegral window + fromIntegral increment :: Word64) <= fromIntegral (maxBound :: Word32))
                $ throwSTM exceptionWindowSizeOverflow
            writeTVar (chanWindowSizeRemote channel) $! window + increment

connectionChannelRequest :: forall identity stream. MessageStream stream =>
    Connection identity -> stream -> ChannelRequest -> IO ()
connectionChannelRequest connection stream (ChannelRequest channelId typ wantReply dat) = join $ atomically $ do
    getChannelSTM connection channelId >>= \case
        ChannelOpening {} -> throwSTM exceptionInvalidChannelState
        ChannelClosing    -> pure $ pure () -- FIXME
        ChannelRunning channel -> case chanApplication channel of
            ChannelApplicationSession sessionState -> case typ of
                "env" -> interpret $ \(ChannelRequestEnv name value) -> do
                    Environment env <- readTVar (sessEnvironment sessionState)
                    writeTVar (sessEnvironment sessionState) $! Environment $ (SBS.fromShort name, SBS.fromShort value):env
                    pure $ success channel
                "pty-req" -> interpret $ \(ChannelRequestPty settings) -> do
                    writeTVar (sessPtySettings sessionState) (Just settings)
                    pure $ success channel
                "shell" -> interpret $ \ChannelRequestShell -> do
                    env    <- readTVar (sessEnvironment sessionState)
                    pty    <- readTVar (sessPtySettings sessionState)
                    stdin  <- pure (sessStdin  sessionState)
                    stdout <- pure (sessStdout sessionState)
                    stderr <- pure (sessStderr sessionState)
                    let SessionHandler handler = sessHandler sessionState
                    pure do
                        forkSessionHandler stream channel stdin stdout stderr $
                            handler env (TermInfo <$> pty) Nothing stdin stdout stderr
                        success channel
                "exec" -> interpret $ \(ChannelRequestExec command) -> do
                    env    <- readTVar (sessEnvironment sessionState)
                    pty    <- readTVar (sessPtySettings sessionState)
                    stdin  <- pure (sessStdin  sessionState)
                    stdout <- pure (sessStdout sessionState)
                    stderr <- pure (sessStderr sessionState)
                    let SessionHandler handler = sessHandler sessionState
                    pure do
                        forkSessionHandler stream channel stdin stdout stderr $
                            handler env (TermInfo <$> pty) (Just command) stdin stdout stderr
                        success channel
                -- "signal" ->
                -- "exit-status" ->
                -- "exit-signal" ->
                -- "window-change" ->
                _ -> pure $ failure channel
            ChannelApplicationDirectTcpIp {} -> pure $ failure channel
    where
        interpret f     = maybe (throwSTM exceptionInvalidChannelRequest) f (runGet dat)
        success channel = when wantReply $ sendMessage stream $ ChannelSuccess (chanIdRemote channel)
        failure channel = when wantReply $ sendMessage stream $ ChannelFailure (chanIdRemote channel)

forkDirectTcpIpHandler :: forall stream. MessageStream stream =>
    stream -> Channel -> DirectTcpIpState -> IO () -> IO ()
forkDirectTcpIpHandler stream channel st handle = do
    registerThread channel handle supervise
    where
        supervise :: Async.Async () -> IO ()
        supervise thread = do
            continue <- join $ atomically
                $   waitOutput
                <|> waitExit thread
                <|> waitLocalWindowAdjust
            when continue $ supervise thread

        waitExit :: Async.Async () -> STM (IO Bool)
        waitExit thread = do
            eof <- Async.waitCatchSTM thread >>= \case
                Right _ -> pure True
                Left  _ -> pure False
            writeTVar (chanClosed channel) True
            pure do
                when eof $ sendMessage stream $ ChannelEof (chanIdRemote channel)
                sendMessage stream $ ChannelClose (chanIdRemote channel)
                pure False

        waitOutput :: STM (IO Bool)
        waitOutput = do
            bs <- B.dequeueShortSTM (dtiStreamOut st) (chanMaxPacketSizeRemote channel)
            pure do
                sendMessage stream $ ChannelData (chanIdRemote channel) bs
                pure True

        waitLocalWindowAdjust :: STM (IO Bool)
        waitLocalWindowAdjust = do
            increment <- B.getRecommendedWindowAdjustSTM (dtiStreamIn st)
            window <- readTVar (chanWindowSizeLocal channel)
            writeTVar (chanWindowSizeLocal channel) $! window + increment
            pure do
                sendMessage stream $ ChannelWindowAdjust (chanIdRemote channel) increment
                pure True

forkSessionHandler :: forall stream. MessageStream stream =>
    stream -> Channel -> B.TWindowBuffer -> B.TWindowBuffer -> B.TWindowBuffer -> IO ExitCode -> IO ()
forkSessionHandler stream channel stdin stdout stderr run = do
    registerThread channel run supervise
    where
        -- The supervisor thread waits for several event sources simultaneously,
        -- handles them and loops until the session thread has terminated and exit
        -- has been signaled or the channel/connection got closed.
        supervise :: Async.Async ExitCode -> IO ()
        supervise thread = do
            continue <- join $ atomically $
                -- NB: The order is critical: Another order would cause a close
                -- or eof to be sent before all data has been flushed.
                    waitStdout
                <|> waitStderr
                <|> waitExit thread
                <|> waitLocalWindowAdjust
            when continue $ supervise thread

        waitExit :: Async.Async ExitCode -> STM (IO Bool)
        waitExit thread = do
            exitMessage <- Async.waitCatchSTM thread >>= \case
                Right c -> pure $ req "exit-status" $ runPut $ put $ ChannelRequestExitStatus c
                Left  _ -> pure $ req "exit-signal" $ runPut $ put $ ChannelRequestExitSignal "ILL" False "" ""
            writeTVar (chanClosed channel) True
            pure do
                sendMessage stream eofMessage
                sendMessage stream exitMessage
                sendMessage stream closeMessage
                pure False
            where
                req t        = ChannelRequest (chanIdRemote channel) t False
                eofMessage   = ChannelEof (chanIdRemote channel)
                closeMessage = ChannelClose (chanIdRemote channel)

        waitStdout :: STM (IO Bool)
        waitStdout = do
            bs <- B.dequeueShortSTM stdout (chanMaxPacketSizeRemote channel)
            pure do
                sendMessage stream $ ChannelData (chanIdRemote channel) bs
                pure True

        waitStderr :: STM (IO Bool)
        waitStderr = do
            bs <- B.dequeueShortSTM stderr (chanMaxPacketSizeRemote channel)
            pure do
                sendMessage stream $ ChannelExtendedData (chanIdRemote channel) 1 bs
                pure True

        waitLocalWindowAdjust :: STM (IO Bool)
        waitLocalWindowAdjust = do
            increment <- B.getRecommendedWindowAdjustSTM stdin
            window <- readTVar (chanWindowSizeLocal channel)
            writeTVar (chanWindowSizeLocal channel) $! window + increment
            pure do
                sendMessage stream $ ChannelWindowAdjust (chanIdRemote channel) increment
                pure True

getChannelSTM :: Connection identity -> ChannelId -> STM ChannelState
getChannelSTM conn lid = do
    channels <- readTVar (connChannels conn)
    case M.lookup lid channels of
        Just channel -> pure channel
        Nothing      -> throwSTM exceptionInvalidChannelId

insertChannelSTM :: Connection identity -> ChannelId -> ChannelState -> STM ()
insertChannelSTM conn lid chst = do
    channels <- readTVar (connChannels conn)
    writeTVar (connChannels conn) $! M.insert lid chst channels

deleteChannelSTM :: Connection identity -> ChannelId -> STM ()
deleteChannelSTM conn lid = do
    channels <- readTVar (connChannels conn)
    writeTVar (connChannels conn) $! M.delete lid channels

-- Two threads are forked: a worker thread running as Async and a
-- supervisor thread which is registered with the channel.
-- -> The worker thread does never outlive the supervisor thread (`withAsync`).
-- -> The supervisor thread terminates itself when either the worker thread
--    has terminated (`waitExit`) or gets cancelled when the channel/connection
--    gets closed.
-- -> The supervisor thread is started even if a thread is already running.
--    It is blocked until it is notified that it is the only one
--    running and its Async has been registered with the channel (meaning
--    it will be reliably cancelled on main thread termination).
registerThread :: Channel -> IO a -> (Async.Async a -> IO ()) -> IO ()
registerThread channel run supervise = do
    barrier <- newTVarIO False
    let prepare = Async.async do
            atomically $ readTVar barrier >>= check
            Async.withAsync run supervise
    let abort = Async.cancel
    let register thread =
            putTMVar (chanThread channel) thread
            <|> throwSTM exceptionAlreadyExecuting
    bracketOnError prepare abort $ \thread -> atomically $
        register thread >> writeTVar barrier True

selectFreeLocalChannelId :: Connection identity -> M.Map ChannelId a -> Maybe ChannelId
selectFreeLocalChannelId connection m
    | M.size m >= fromIntegral maxCount = Nothing
    | otherwise = f (ChannelId 0) $ M.keys m
    where
        f i []          = Just i
        f (ChannelId i) (ChannelId k:ks)
            | i == k    = f (ChannelId $ i+1) ks
            | otherwise = Just (ChannelId i)
        maxCount = channelMaxCount (connConfig connection)
