module Network.SSH.Client.HostKeyVerifier where

import           Control.Applicative
import           Control.Monad
import qualified Crypto.MAC.HMAC        as HMAC
import qualified Crypto.Hash.Algorithms as Hash
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Char8  as BS8
import qualified Data.ByteArray         as BA
import qualified Data.ByteArray.Parse   as BP
import           Data.List.NonEmpty (NonEmpty (..))
import           Data.Maybe
import           Data.Word
import           System.FilePath
import           System.Directory

import Network.SSH.Address
import Network.SSH.Key
import Network.SSH.Message
import Network.SSH.Name
import Network.SSH.Encoding

type HostKeyVerifier = Address -> PublicKey -> IO VerificationResult

data VerificationResult
    = VerificationFailed BS.ByteString
    | VerificationPassed
    deriving (Eq, Ord, Show)

acceptKnownHostsFromFile :: FilePath -> HostKeyVerifier
acceptKnownHostsFromFile path host key = do
    absolutePath <- getAbsolutePath
    bs <- BS.readFile absolutePath
    pure if any match (parseKnownHostsFile bs)
        then VerificationPassed
        else VerificationFailed $ BS8.pack $ absolutePath ++ ": no match" 
    where
        match (KnownHost (n :| ns) knownKey) =
            let nameMatch = matchKnownHostName host n || any (matchKnownHostName host) ns
                keyMatch  = key == knownKey
            in  nameMatch && keyMatch
        getAbsolutePath = canonicalizePath =<< case splitPath path of
            ("~/":ps) -> (joinPath . (:ps)) <$> getUserDocumentsDirectory
            _         -> pure path

---------------------------------------------------------------------------------------------------
-- KNOWN_HOSTS FILE
---------------------------------------------------------------------------------------------------

data KnownHost = KnownHost
    { khNames     :: NonEmpty KnownHostName
    , khPublicKey :: PublicKey
    } deriving (Eq, Show)

data KnownHostName
    = KnownHostHMAC BS.ByteString BS.ByteString
    | KnownHostPlain BS.ByteString
    deriving (Eq, Show)

matchKnownHostName :: Address -> KnownHostName -> Bool
matchKnownHostName (Address (Name host) (Port port)) = \case
    KnownHostHMAC salt hash -> BA.eq hash (HMAC.hmac salt n :: HMAC.HMAC Hash.SHA1)
    KnownHostPlain knownName -> knownName == n
    where
        n = case port of
            22 -> host
            _  -> "[" <> host <> "]:" <> BS8.pack (show port)

parseKnownHostsFile :: BS.ByteString -> [KnownHost]
parseKnownHostsFile bs = mapMaybe p ls
    where
        ls = BS.splitWith isLineBreak bs
        p l = parse parseLine (BS.snoc l 0x20)

parseLine :: BP.Parser BS.ByteString KnownHost
parseLine = parseHashed <|> parsePlain
    where
        parseHashed = do
            void $ BP.bytes ("|1|" :: BS.ByteString)
            hmacSalt64 <- BP.takeWhile (not . isPipe)
            hmacSalt <- parse parseBase64 hmacSalt64
            void $ BP.bytes ("|" :: BS.ByteString)
            hmacHash64 <- BP.takeWhile (not . isWhiteSpace)
            hmacHash <- parse parseBase64 hmacHash64
            BP.skipWhile isWhiteSpace
            void $ BP.takeWhile (not . isWhiteSpace)
            BP.skipWhile isWhiteSpace
            key64 <- BP.takeWhile (not . isWhiteSpace)
            keyBS <- parse parseBase64 key64
            key <- runGetter keyBS getUnframedPublicKey 
            pure $ KnownHost (pure $ KnownHostHMAC hmacSalt hmacHash) key
        parsePlain = do
            h <- BP.takeWhile (not . isWhiteSpace)
            hs <- case BS.splitWith (== (fromIntegral (fromEnum ','))) h of
                [] -> fail mempty
                (x:xs) -> pure (x:|xs)
            BP.skipWhile isWhiteSpace
            void $ BP.takeWhile (not . isWhiteSpace)
            BP.skipWhile isWhiteSpace
            key64 <- BP.takeWhile (not . isWhiteSpace)
            keyBS <- parse parseBase64 key64
            key <- runGetter keyBS getUnframedPublicKey
            pure $ KnownHost (fmap KnownHostPlain hs) key

isWhiteSpace, isLineBreak, isPipe :: Word8 -> Bool
isWhiteSpace b = b == 0x20 || b == 0x09
isLineBreak b = b == 0x0a || b == 0x0d
isPipe b = b == 0x7c

parse :: MonadFail m => BP.Parser BS.ByteString a -> BS.ByteString -> m a
parse p bs = case BP.parse p bs of
    BP.ParseOK _ x -> pure x
    BP.ParseFail e  -> fail e
    BP.ParseMore c -> case c Nothing of
        BP.ParseOK _ x -> pure x
        BP.ParseFail e -> fail e
        _              -> fail "eof"

getUnframedPublicKey :: Get PublicKey
getUnframedPublicKey = getName >>= \case
    Name "ssh-ed25519" -> PublicKeyEd25519 <$> getEd25519PublicKey
    Name "ssh-rsa"     -> PublicKeyRSA <$> getRsaPublicKey
    _                  -> fail "must ignore unsupported public key types"
