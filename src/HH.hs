{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -fdefer-type-errors #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}
{-# OPTIONS_GHC -w #-}

module Main (main) where

import           Control.Applicative ((<$>), (<*>))
import           Control.Exception (Exception, throwIO)
import           Control.Monad
import           Control.Monad.IO.Class (MonadIO, liftIO)

import           Data.Bits ((.&.), shiftR)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import           Data.Data (Data)
import           Data.Maybe (fromMaybe, maybeToList)
import           Data.Monoid ((<>), mempty)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import           Data.Time
import           Data.Time.Clock.POSIX
import           Data.Time.Format (formatTime)
import           Data.Typeable (Typeable)
import           Data.Word (Word16, Word32, Word64)
import           System.Locale (defaultTimeLocale)

import           System.Environment (getArgs)
import           System.IO (Handle, BufferMode(..), hSetBuffering, hSetBinaryMode, hClose)
import           Text.PrettyPrint.Boxes hiding ((<>))

import           Data.ProtocolBuffers
import           Data.ProtocolBuffers.Orphans ()
import           Data.Serialize.Get
import           Data.Serialize.Put

import           Data.Conduit
import           Data.Conduit.Cereal
import           Data.Conduit.Network

import           Hadoop.Protobuf.ClientNameNode
import           Hadoop.Protobuf.Hdfs
import           Hadoop.Protobuf.Headers

import qualified Data.HashMap.Strict as H
import           Data.ProtocolBuffers.Internal

------------------------------------------------------------------------

-- TODO Handle SIGPIPE
-- import Posix
-- main = installHandler sigPIPE Ignore Nothing

f ! x = getField (f x)

main :: IO ()
main = runTCPClient (clientSettings 8020 "hadoop1") $ \server -> do
    putStrLn $ "Connected to " ++ show (appSockAddr server)
    appSource server $$ app =$ appSink server

app :: Conduit ByteString IO ByteString
app = do
    [path] <- liftIO getArgs
    lst <- sudo "cloudera" (getListing path)

    let xs = concatMap (dlPartialListing!) . maybeToList . (glDirList!) $ lst

    let getPerms     = fromIntegral . (fpPerm!) . (fsPermission!)
        getPath      = T.decodeUtf8 . (fsPath!)
        getBlockRepl = fromMaybe 0 . (fsBlockReplication!)

        hdfs2utc ms  = posixSecondsToUTCTime (fromIntegral ms / 1000)
        getModTime   = hdfs2utc . (fsModificationTime!)

        col a f = vcat a (map (text . f) xs)

    liftIO $ do
        putStrLn $ "Found " <> show (length xs) <> " items"

        printBox $ col left  (\x -> formatMode (fsFileType! x) (getPerms x))
               <+> col right (formatBlockRepl . getBlockRepl)
               <+> col left  (T.unpack . (fsOwner!))
               <+> col left  (T.unpack . (fsGroup!))
               <+> col right (formatSize . (fsLength!))
               <+> col right (formatUTC . getModTime)
               <+> col left  (T.unpack . getPath)

sudo :: Text -> Remote a -> ConduitM ByteString ByteString IO a
sudo user rpc = do
    sourcePut (putRequest context header request)
    header <- sinkGet decodeLengthPrefixedMessage
    case rspStatus ! header of
      Success -> sinkGet (rpcDecode rpc <$> getResponse) >>= throwLeft
      _       -> sinkGet getError >>= liftIO . throwIO
  where
    throwLeft (Left err) = liftIO (throwIO err)
    throwLeft (Right x)  = return x

    context = IpcConnectionContext
        { ctxProtocol = putField (Just (rpcProtocolName rpc))
        , ctxUserInfo = putField (Just UserInformation
            { effectiveUser = putField (Just user)
            , realUser      = mempty
            })
        }

    header = RpcRequestHeader
        { reqKind       = putField (Just ProtocolBuffer)
        , reqOp         = putField (Just FinalPacket)
        , reqCallId     = putField 1
        }

    request = RpcRequest
        { reqMethodName      = putField (rpcMethodName rpc)
        , reqBytes           = putField (Just (rpcBytes rpc))
        , reqProtocolName    = putField (rpcProtocolName rpc)
        , reqProtocolVersion = putField (rpcProtocolVersion rpc)
        }

------------------------------------------------------------------------

data RpcError = RpcError Text Text
    deriving (Show, Eq, Data, Typeable)

instance Exception RpcError

------------------------------------------------------------------------

data Remote a = Remote
    { rpcProtocolName    :: Text
    , rpcProtocolVersion :: Word64
    , rpcMethodName      :: Text
    , rpcBytes           :: ByteString
    , rpcDecode          :: ByteString -> Either RpcError a
    }

rpc :: (Decode b, Encode a) => Text -> Word64 -> Text -> a -> Remote b
rpc protocol ver method arg = Remote protocol ver method (toBytes arg) fromBytes

getListing :: FilePath -> Remote GetListingResponse
getListing path = rpc "org.apache.hadoop.hdfs.protocol.ClientProtocol" 1 "getListing" GetListingRequest
                { glSrc          = putField (T.pack path)
                , glStartAfter   = putField ""
                , glNeedLocation = putField False
                }

------------------------------------------------------------------------

-- hadoop-2.1.0-beta is on version 9
-- see https://issues.apache.org/jira/browse/HADOOP-8990 for differences

putRequest :: IpcConnectionContext -> RpcRequestHeader -> RpcRequest -> Put
putRequest ctx hdr req = do
    putByteString "hrpc"
    putWord8 7  -- version
    putWord8 80 -- auth method (80 = simple, 81 = kerberos/gssapi, 82 = token/digest-md5)
    putWord8 0  -- ipc serialization type (0 = protobuf)

    putBlob (toBytes ctx)
    putBlob (toLPBytes hdr <> toLPBytes req)
  where
    putBlob bs = do
        putWord32be (fromIntegral (B.length bs))
        putByteString bs

getResponse :: Get ByteString
getResponse = do
    n <- fromIntegral <$> getWord32be
    getByteString n

getError :: Get RpcError
getError = RpcError <$> getText <*> getText
  where
    getText = do
        n <- fromIntegral <$> getWord32be
        T.decodeUtf8 <$> getByteString n

toBytes :: Encode a => a -> ByteString
toBytes = runPut . encodeMessage

toLPBytes :: Encode a => a -> ByteString
toLPBytes = runPut . encodeLengthPrefixedMessage

fromBytes :: Decode a => ByteString -> Either RpcError a
fromBytes bs = case runGetState decodeMessage bs 0 of
    Left err      -> Left (RpcError "fromBytes" (T.pack err))
    Right (x, "") -> Right x
    Right (_, _)  -> Left (RpcError "fromBytes" "decoded response but did not consume enough bytes")

------------------------------------------------------------------------

type Path      = Text
type Owner     = Text
type Group     = Text
type Size      = Word64
type BlockRepl = Word32
type Perms     = Word16

formatFile :: Path -> Owner -> Group -> Size -> BlockRepl -> UTCTime -> FileType -> Perms -> Box
formatFile path o g sz mbr utc t p = text (formatMode t p)
                                 <+> text (if mbr == 0 then "-" else (show .fromIntegral) mbr)
                                 <+> text (T.unpack o)
                                 <+> text (T.unpack g)
                                 <+> text (show sz)
                                 <+> text (formatUTC utc)
                                 <+> text (T.unpack path)

formatSize :: Word64 -> String
formatSize b | b == 0               = "0"
             | b < 1000             = show b <> "B"
             | b < 1000000          = show (b `div` 1000) <> "K"
             | b < 1000000000       = show (b `div` 1000000) <> "M"
             | b < 1000000000000    = show (b `div` 1000000000) <> "G"
             | b < 1000000000000000 = show (b `div` 1000000000000) <> "T"

formatBlockRepl :: Word32 -> String
formatBlockRepl x | x == 0    = "-"
                  | otherwise = show x

formatUTC :: UTCTime -> String
formatUTC = formatTime defaultTimeLocale "%Y-%m-%d %H:%M"

formatMode :: FileType -> Perms -> String
formatMode File    = ("-" <>) . formatPerms
formatMode Dir     = ("d" <>) . formatPerms
formatMode SymLink = ("l" <>) . formatPerms

formatPerms :: Perms -> String
formatPerms perms = format (perms `shiftR` 6)
                 <> format (perms `shiftR` 3)
                 <> format perms
  where
    format p = conv 0x4 "r" p
            <> conv 0x2 "w" p
            <> conv 0x1 "x" p

    conv bit str p | (p .&. bit) /= 0 = str
                   | otherwise        = "-"