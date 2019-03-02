module Lib
  ( someFunc
  )
where

import           Control.Monad.IO.Class
import           Universum
import           Net.Net                       as N
import           Network.Socket                 ( SockAddr(SockAddrInet) )
import qualified Control.Concurrent.Async      as CA

someFunc :: (MonadIO m, CanNetwork m) => m ()
someFunc = do
  server         <- listen (SockAddrInet 9069 (localAddr 100))
  (bidichan, as) <- accept server
  let ochan = (bidichan ^. outChan)
  let ichan = (bidichan ^. inChan)
  send ochan (newMessage "dupa")
  msg <- receive ichan
  send ochan msg
  send ochan (newMessage "dupa")
  (c2, _) <- connectUntilSuccess (SockAddrInet 9090 (localAddr 1))
  send (c2 ^. outChan) (newMessage "hahaha")
  x <- receive (c2 ^. inChan)
  send ochan x
  send ochan (newMessage "dupa")
  send ochan (newMessage "dupa")
  send ochan (newMessage "dupaXXX")
  liftIO $ CA.wait as

