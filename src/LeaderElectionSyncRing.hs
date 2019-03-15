{-# LANGUAGE TemplateHaskell #-}

module LeaderElectionSyncRing
  ( runElection
  )
where

import           Universum
import qualified Network.Socket                as S
import qualified Control.Lens                  as L
import qualified Net.Net                       as N
import           Control.Lens.TH                ( )
import qualified Control.Concurrent.Async      as CA
import qualified Control.Concurrent.STM        as CS

protocolPort = 9069
statePort = 9070
numNodes = 10 :: Word8

shiftr :: [a] -> [a]
shiftr []       = []
shiftr (x : xs) = xs ++ [x]

createNodes :: Word8 -> [Node]
createNodes num =
  [ Node (fromIntegral id) (protoAddr self) (protoAddr nb) (stateAddr self)
  | (id, self, nb) <- zip3 ids addresses (shiftr addresses)
  ]
 where
  ids       = [firstAddr .. lastAddr]
  addresses = N.localAddr <$> ids
  firstAddr = 10 :: Word8
  lastAddr  = firstAddr + num
  protoAddr = S.SockAddrInet protocolPort
  stateAddr = S.SockAddrInet statePort

data Node = Node {
    _selfId :: Int
    , _selfAddr :: S.SockAddr
    , _neighbourAddr :: S.SockAddr
    , _selfStateAddr :: S.SockAddr
} deriving (Show)

L.makeClassy ''Node

runElection :: (MonadIO m) => Word8 -> m ()
runElection numberOfNodes = do
  let nodes = createNodes numberOfNodes
  liftIO $ CA.mapConcurrently_ nodeProgram nodes

nodeProgram :: (MonadIO m) => Node -> m ()
nodeProgram selfNode = do
  leaderAnnouncement <- liftIO $ CS.atomically (CS.newTVar False)
  liftIO $ CA.concurrently_ (runAnn leaderAnnouncement)
                            (runProg leaderAnnouncement)
 where
  runAnn  = runStateServer selfNode
  runProg = protocolProgram selfNode


runStateServer :: (MonadIO m, N.CanNetwork m) => Node -> (CS.TVar Bool) -> m ()
runStateServer serverNode ann = do
  serv <- N.listen (serverNode ^. selfStateAddr)
  loop serv
 where
  loop serv = do
    (bchan, _) <- N.accept serv
    -- TODO handle resources (close client)
    -- TODO handle client asynchronously
    isLeader   <- liftIO $ CS.atomically (CS.readTVar ann)
    let msg = N.newMessage (output isLeader)
    N.send (bchan ^. N.outChan) msg
    loop serv
  output isLeader = case isLeader of
    True  -> "I am the leader"
    False -> "I am the servant"

protocolProgram :: (MonadIO m, N.CanNetwork m) => Node -> (CS.TVar Bool) -> m ()
protocolProgram selfNode announcement = do
  serv <- N.listen (selfNode ^. selfAddr)
  ((selfChan', sw), (neighbourChan', nw)) <- liftIO $ CA.concurrently
    (N.accept serv)
    (N.connectUntilSuccess (selfNode ^. neighbourAddr))
  let neighbourChan = (neighbourChan' ^. N.outChan)
  let selfChan      = (selfChan' ^. N.inChan)
  N.send neighbourChan (N.newMessage strId)
  _ <- loop selfChan neighbourChan
  liftIO . void $ CA.wait sw
  liftIO . void $ CA.wait nw
 where
  strId = show (selfNode ^. selfId)
  loop selfChan neighbourChan = do
    msg <- N.receive selfChan
    resolve msg neighbourChan
    loop selfChan neighbourChan
  resolve msg neighbourChan
    | msg ^. N.content < strId = return ()
    | msg ^. N.content > strId = N.send neighbourChan msg
    | otherwise = liftIO $ CS.atomically (CS.writeTVar announcement True)

