module Lib
  ( someFunc
  )
where

import           Control.Monad.IO.Class
import qualified LeaderElectionSyncRing        as LESR

someFunc :: (MonadIO m) => m ()
someFunc = LESR.runElection 50

