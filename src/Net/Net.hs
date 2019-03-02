{-# LANGUAGE TemplateHaskell #-}

module Net.Net
  ( CanNetwork
  , BidiChannel
  , OutboundChannel
  , InboundChannel
  , connectUntilSuccess
  , localAddr
  , listen
  , receive
  , send
  , accept
  , connect
  , outChan
  , inChan
  , newMessage
  )
where

import qualified Network.Socket                as S
import qualified Network.Socket.ByteString     as NS
import           Universum               hiding ( (^.) )
import           Control.Monad.IO.Class         ( )
import           Control.Lens                  as L
import           Control.Lens.TH                ( )
import qualified Control.Concurrent.STM        as CS
import qualified Data.ByteString               as BS
import qualified Control.Concurrent.Async      as CA
import qualified Control.Concurrent            as C
import           Control.Monad.Except

data Message = Message {
    _content :: ByteString
} deriving (Show, Eq)

data Server = Server {
    _serverSock :: S.Socket
}

data OutboundChannel = OutboundChannel (CS.TChan Message)
data InboundChannel = InboundChannel (CS.TChan Message)
data BidiChannel = BidiChannel {
    _outChan :: OutboundChannel
    , _inChan :: InboundChannel
}

class CanNetwork m where
    send :: OutboundChannel -> Message -> m ()
    receive :: InboundChannel -> m Message
    listen :: S.SockAddr -> m Server
    accept :: Server -> m (BidiChannel, CA.Async ())
    connect :: S.SockAddr -> m (BidiChannel, CA.Async ())

connectUntilSuccess :: (MonadIO m) => S.SockAddr -> m (BidiChannel, CA.Async ())
connectUntilSuccess addr = liftIO $ catchError (connect addr) tryInAWhile
 where
  tryInAWhile _ = sleep >> connectUntilSuccess addr
  sleep = C.threadDelay 100000

localAddr :: Word8 -> S.HostAddress
localAddr x = S.tupleToHostAddress (127, 0, 0, x)

newSocket :: (MonadIO m) => m S.Socket
newSocket = liftIO $ S.socket S.AF_INET S.Stream S.defaultProtocol

newMessage :: ByteString -> Message
newMessage = Message

makeClassy ''Server
makeClassy ''Message
makeClassy ''BidiChannel

runPublisher :: (MonadIO m) => S.Socket -> OutboundChannel -> m ()
runPublisher sock (OutboundChannel chan) = liftIO $ runLoop
 where
  runLoop :: IO ()
  runLoop = do
    msg <- nextMessage
    NS.sendAll sock ((msg ^. content) <> "\n")
    runLoop
  nextMessage = CS.atomically (CS.readTChan chan)

runListener :: (MonadIO m) => S.Socket -> InboundChannel -> m ()
runListener sock (InboundChannel chan) = liftIO $ (runLoop "")
 where
  runLoop :: ByteString -> IO ()
  runLoop leftover = do
    chunk <- NS.recv sock 4096
    let joined   = leftover <> chunk
    let splitted = BS.split 10 joined
    case nonEmpty splitted of
      Just nel -> putMessages (Message <$> (init nel)) >> (runLoop (last nel))
      Nothing  -> runLoop ""
  putMessages :: [Message] -> IO ()
  putMessages = traverse_ (\msg -> (CS.atomically (CS.writeTChan chan msg)))

createBidiChanAndRun :: S.Socket -> IO (BidiChannel, CA.Async ())
createBidiChanAndRun sock = do
  oc <- CS.atomically CS.newTChan
  ic <- CS.atomically CS.newTChan
  let ochan = OutboundChannel oc
  let ichan = InboundChannel ic
  as <- CA.async
    $ CA.concurrently_ (runPublisher sock ochan) (runListener sock ichan)
  return ((BidiChannel ochan ichan), as)

instance CanNetwork IO where
    listen addr = do
        s <- newSocket
        S.bind s addr
        S.listen s 5
        return (Server s)

    accept ser = do
        (sock, _) <- S.accept (L.view serverSock ser)
        createBidiChanAndRun sock

    send (OutboundChannel chan) msg = CS.atomically (CS.writeTChan chan msg)

    receive (InboundChannel chan) = CS.atomically (CS.readTChan chan)

    connect addr = do
        sock <- newSocket
        S.connect sock addr
        createBidiChanAndRun sock
