{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE ViewPatterns          #-}

module Network.Wai.OAuth where

import           Control.Applicative        (Applicative, (<$>), (<*>), (<|>))
import           Control.Arrow              (second, (***))
import           Control.Concurrent.MonadIO (MonadIO, liftIO)
import           Control.Error.Util         (note)
import           Control.Monad.Reader       (ask)
import           Control.Monad.State
import           Control.Monad.Trans.Either
import           Control.Monad.Trans.Reader (runReaderT)
import           Data.Attoparsec.Char8      hiding (isDigit)
import           Data.ByteString            (ByteString)
import           Data.Char                  (isAlpha, isAscii, isDigit)
import           Data.Digest.Pure.SHA       (bytestringDigest, hmacSha1)
import           Data.Functor
import           Data.IORef.Lifted          (newIORef, readIORef, writeIORef)
import           Data.List                  (find, group, partition, sort)
import           Data.Maybe                 (fromMaybe)
import           Data.Monoid                (mconcat, (<>))
import           Data.Text                  (Text)
import           Network.HTTP.Types         (badRequest400, hContentType, ok200,
                                             parseSimpleQuery, queryToQueryText,
                                             unauthorized401, urlDecode)
import           Network.Wai
import           Network.Wai.Parse          (RequestBodyType (..),
                                             getRequestBodyType)

import           Debug.Trace

import qualified Data.ByteString            as B
import qualified Data.ByteString.Base16     as B16
import qualified Data.ByteString.Base64     as B64
import qualified Data.ByteString.Lazy       as BL
import qualified Data.Conduit               as C
import qualified Data.Conduit.List          as CL
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as E

import           Network.Wai.OAuth.Types


emptyOAuthParams :: OAuthParams
emptyOAuthParams = OAuthParams "" "" Plaintext Nothing Nothing "" Nothing Nothing



runOAuthM :: Monad m => OAuthConfig m -> Request -> OAuthM m a -> m (Either OAuthError a)
runOAuthM config req = (`runReaderT` config) . runEitherT . (`evalStateT` req) . runOAuthT

query :: Request -> SimpleQueryText
query = fmap (second (fromMaybe "")) . queryToQueryText . queryString


preprocessRequest :: MonadIO m => OAuthM m OAuthState
preprocessRequest = do
    request <- get
    (oauths, rest) <- splitOAuthParams
    url <- oauthEither $ generateNormUrl request
    let getM name = mfilter ( /= "") $ E.encodeUtf8 <$> lookup name oauths
        getE name = note (MissingParameter name) $ getM name
        getOrEmpty name = fromMaybe "" $ getM name
    oauth  <- oauthEither $ do
        signMeth <- getE "oauth_signature_method" >>= extractSignatureMethod
        signature <- getE "oauth_signature"
        consKey <- getE "oauth_consumer_key"
        return $ OAuthParams consKey (getOrEmpty "oauth_token") signMeth
            (getM "oauth_callback") (getM "oauth_verifier") signature (getM "oauth_nonce") (getM "oauth_timestamp" >>= parseTS)
    return OAuthState { oauthRawParams = oauths, reqParams = rest, reqUrl = url, reqMethod = requestMethod request, oauthParams = oauth }
  where
    parseTS = maybeResult . parse decimal


authenticated :: MonadIO m => OAuthM m OAuthParams
authenticated = do
    oauthState <- preprocessRequest
    config <- ask
    verifyOAuthSignature (cfgConsumerSecretLookup config) (cfgAccessTokenSecretLookup config) oauthState
    return $ oauthParams oauthState


oneLegged :: MonadIO m => OAuthM m ()
oneLegged = do
    OAuthConfig {..} <- ask
    oauthState <- preprocessRequest
    verifyOAuthSignature cfgConsumerSecretLookup emptyTokenLookup oauthState

twoLeggedRequestTokenRequest :: MonadIO m => OAuthM m Response
twoLeggedRequestTokenRequest = do
    OAuthConfig {..} <- ask
    twoLegged cfgConsumerSecretLookup emptyTokenLookup cfgTokenGenerator

twoLeggedAccessTokenRequest :: MonadIO m => OAuthM m Response
twoLeggedAccessTokenRequest = do
    OAuthConfig {..} <- ask
    twoLegged cfgConsumerSecretLookup cfgRequestTokenSecretLookup cfgTokenGenerator

twoLegged :: MonadIO m => SecretLookup m -> SecretLookup m -> (ByteString -> m (ByteString, ByteString)) -> OAuthM m Response
twoLegged consLookup tokenLookup secretCreation = do
    responseString <- processOAuthRequest consLookup tokenLookup secretCreation noProcessing
    return $ mkResponse200 responseString

noProcessing :: Monad m => OAuthParams -> OAuthM m ()
noProcessing = const (return ())

processOAuthRequest :: MonadIO m => SecretLookup m -> SecretLookup m -> (ByteString -> m (ByteString, ByteString)) -> (OAuthParams -> OAuthM m ()) -> OAuthM m [(ByteString, ByteString)]
processOAuthRequest consumerLookup tokenLookup secretCreation customProcessing = do
    oauth <- preprocessRequest
    OAuthConfig {..} <- ask
    OAuthT . lift . EitherT .lift $ do
        maybeError <- cfgNonceTimestampCheck $ oauthParams oauth
        return $ maybe (Right ()) Left  maybeError
    _ <- customProcessing (oauthParams oauth)
    _ <- verifyOAuthSignature consumerLookup tokenLookup oauth
    (token, secret) <- liftOAuthT $ secretCreation $ opConsumerKey $ oauthParams oauth
    return [("oauth_token", token), ("oauth_token_secret", secret)]

threeLeggedRequestTokenRequest :: MonadIO m => OAuthM m Response
threeLeggedRequestTokenRequest = do
    OAuthConfig {..} <- ask
    responseParams <- processOAuthRequest cfgConsumerSecretLookup emptyTokenLookup cfgTokenGenerator noProcessing
    return $ mkResponse200 $ ("oauth_callback_confirmed", "true") : responseParams

threeLeggedAccessTokenRequest :: MonadIO m => OAuthM m Response
threeLeggedAccessTokenRequest = do
    OAuthConfig {..} <- ask
    let verifierCheck params = do
            storedVerifier <- lift $ cfgVerifierLookup (opConsumerKey params, opToken params)
            case opVerifier params of
                Just ((==) storedVerifier -> True) -> oauthEither $ Right ()
                Just wrongVerifier               -> oauthEither $ Left (InvalidVerifier wrongVerifier)
                Nothing                          -> oauthEither $ Left (MissingParameter "oauth_verifier")
    responseParams <- processOAuthRequest cfgConsumerSecretLookup cfgRequestTokenSecretLookup cfgTokenGenerator verifierCheck
    return $ mkResponse200 responseParams


mkResponse200 :: [(ByteString, ByteString)] -> Response
mkResponse200 params = responseLBS ok200 [(hContentType, "application/x-www-form-urlencoded")] (BL.fromStrict body)
  where
    body = B.intercalate "&" $ fmap paramString params
    paramString (a,b) = B.concat [a, "=", b]

emptyTokenLookup :: Monad m => SecretLookup m
emptyTokenLookup = const (return $ Right "")

verifyOAuthSignature :: MonadIO m => SecretLookup m -> SecretLookup m -> OAuthState -> OAuthM m ()
verifyOAuthSignature consumerLookup tokenLookup  (OAuthState oauthRaw rest url method oauth) = do
    cons <- wrapped consumerLookup $ opConsumerKey oauth
    token <- wrapped tokenLookup $ opToken oauth
    let secrets = (cons, token)
        cleanOAuths = filter ((/=) "oauth_signature" . fst) oauthRaw
    let serverSignature = genOAuthSignature oauth secrets method url (cleanOAuths <> rest)
        clientSignature = opSignature oauth
    unless (clientSignature == serverSignature) $
        oauthEither $ Left $ InvalidSignature clientSignature
  where
    wrapped f = OAuthT . lift . EitherT . lift . f

genOAuthSignature :: OAuthParams -> Secrets -> RequestMethod -> NormalizedURL -> SimpleQueryText -> ByteString
genOAuthSignature OAuthParams {..} secrets method normUrl params = signature
  where
    signature = mkSignature opSignatureMethod secrets baseString
    baseString = genSignatureBase method normUrl paramString
    paramString = genParamString params

mkSignature :: SignatureMethod -> Secrets -> ByteString -> ByteString
mkSignature signatureMethod (consSecret, tokenSecret) content = signature signatureMethod
  where
    signature HMAC_SHA1 = B64.encode $ BL.toStrict $ bytestringDigest $ hmacSha1 (BL.fromStrict $ debug key) (BL.fromStrict $ debug content)
    signature Plaintext = key
    signature RSA_SHA1  = undefined
    key = concatParamStrings [consSecret, tokenSecret]

genSignatureBase :: RequestMethod -> NormalizedURL -> ByteString -> ByteString
genSignatureBase method normUrl params = concatParamStrings [method, normUrl, params]

concatParamStrings :: [ByteString] -> ByteString
concatParamStrings = B.intercalate "&" . map oauthEncodeString

genParamString :: SimpleQueryText -> ByteString
genParamString params = E.encodeUtf8 $ T.intercalate "&" paramPairs
  where
    sortedParams = sort params
    paramPairs = [T.concat [oauthEncode k,"=",oauthEncode v] | (k,v) <- sortedParams]

generateNormUrl :: Request -> Either OAuthError ByteString
generateNormUrl request =
    let secure = isSecure request
        scheme = if secure then "https" else "http"
        hostport = fmap (B.break (58 ==)) (requestHeaderHost request)
        mkPort port = case port of
            ":80" -> if not secure then "" else port
            ":443" -> if secure then "" else port
            p -> p
        path = T.intercalate "/" $ pathInfo request
    in note MissingHostHeader $ do
        (host, port) <- hostport
        return $ B.concat [scheme, "://", host, mkPort port, "/", E.encodeUtf8 path]

splitOAuthParams :: MonadIO m => OAuthM m (SimpleQueryText, SimpleQueryText)
splitOAuthParams = do
    req <- get
    formBody <- formBodyParameters
    oauthEither $ tryInOrder (authHeaderParams req) formBody (query req)
  where
    authHeaderParams req = fromMaybe [] $ (maybeResult . parse parseAuthHeader) =<< lookup "Authentication" (requestHeaders req)

tryInOrder :: SimpleQueryText -> SimpleQueryText -> SimpleQueryText -> Either OAuthError (SimpleQueryText, SimpleQueryText)
tryInOrder authParams bodyParams queryParams =
    case (hasParams authParams, hasParams bodyParams, hasParams queryParams) of
        (True, False, False)  -> extractParams authParams bodyParams queryParams
        (False, True, False)  -> extractParams bodyParams queryParams authParams
        (False, False, True)  -> extractParams queryParams authParams bodyParams
        (False, False, False) -> Left $ MissingParameter "oauth_consumer_key"
        _                     -> Left MultipleOAuthParamLocations
  where
    hasParams = any isOAuthParam
    extractParams as bs cs = let (oauths, rest) = partition isOAuthParam as
                             in  fmap (, rest ++ bs ++ cs) $ findErrors oauths
    isOAuthParam = T.isPrefixOf "oauth_" . fst
    findErrors :: SimpleQueryText -> Either OAuthError SimpleQueryText
    findErrors oauths = let xs = group . sort $ map fst oauths
                            duplicate = fmap (Left . DuplicateParameter . head) $ find ((> 1) . length) xs
                            unsupported = fmap (Left . UnsupportedParameter . fst) $ find (flip notElem oauthParamNames . fst) oauths
                        in  fromMaybe (Right oauths) $ unsupported <|> duplicate

formBodyParameters :: MonadIO m => OAuthM m SimpleQueryText
formBodyParameters = do
    req <- get
    case getRequestBodyType req of
        Just UrlEncoded -> do
            (body, replayedBody) <- liftIO $ replay req
            let req' = req { requestBody = replayedBody }
                params = parseSimpleQuery $ mconcat body
                result = [(E.decodeUtf8 k, E.decodeUtf8 v) | (k, v) <- params]
            modify (const req')
            return result
        _               -> return []

  where
    replay req = do
        body <- requestBody req C.$$ CL.consume
        ichunks <- newIORef body
        let rbody = do
                chunks <- readIORef ichunks
                case chunks of
                    [] -> return ()
                    x:xs -> do
                        writeIORef ichunks xs
                        C.yield x
                        rbody
        return (body, rbody)

oauthEither :: Monad m => Either OAuthError b -> OAuthM m b
oauthEither = OAuthT . lift . hoistEither

liftOAuthT :: Monad m => m a -> OAuthT r s m a
liftOAuthT = OAuthT . lift .lift . lift

extractSignatureMethod :: ByteString -> Either OAuthError SignatureMethod
extractSignatureMethod "HMAC-SHA1" = Right HMAC_SHA1
extractSignatureMethod "RSA-SHA1"  = Right RSA_SHA1
extractSignatureMethod "PLAINTEXT" = Right Plaintext
extractSignatureMethod method      = Left $ UnsupportedSignatureMethod method

oauthParamNames :: [Text]
oauthParamNames = map (T.append "oauth_") ["consumer_key", "callback", "token", "nonce", "timestamp", "signature_method", "signature", "verifier", "version"]

errorAsResponse :: OAuthError -> Response
errorAsResponse err = case err of
    -- 400 - Bad Request
    UnsupportedParameter _ -> r400
    UnsupportedSignatureMethod _ -> r400
    MissingParameter _ -> r400
    MissingHostHeader -> r400
    DuplicateParameter _ -> r400
    MultipleOAuthParamLocations -> r400
    -- 401 - Unauthorized
    InvalidToken _ -> r401
    UsedNonce -> r401
    InvalidConsumerKey _ -> r401
    InvalidSignature _ -> r401
    InvalidVerifier _ -> r401
    ExpiredRequest -> r401
    ExpiredToken _ -> r401
  where
    r400 = resp badRequest400
    r401 = resp unauthorized401
    resp status = responseLBS status [] $ BL.fromStrict $ E.encodeUtf8 $ T.pack $ show err

oauthEncode :: Text -> Text
oauthEncode = T.concatMap enc
  where
    enc c
        | isAscii c && (isAlpha c || isDigit c || c `elem` "-._~") = T.singleton c
        | otherwise = let num = (grouped 2 . B16.encode . E.encodeUtf8 . T.singleton) c
                          hex = B.concat $ map (B.append "%") num
                      in T.toUpper $ E.decodeUtf8 hex

oauthEncodeString :: ByteString -> ByteString
oauthEncodeString = E.encodeUtf8 . oauthEncode . E.decodeUtf8

grouped :: Int -> ByteString -> [ByteString]
grouped n as = if B.null as then [] else result
  where
    (group, rest) = B.splitAt n as
    result = group : grouped n rest

parseAuthHeader :: Parser SimpleQueryText
parseAuthHeader = do
    string "OAuth"
    skipSpace
    sepBy (mfilter (T.isPrefixOf "oauth_" . fst) lineParser) separator
  where
    separator = do
        char ','
        skipSpace

lineParser :: Parser (Text, Text)
lineParser = do
        key <- takeTill ('=' ==)
        value <- "=\"" .*> takeTill ('"' ==) <*. "\""
        return (E.decodeUtf8 $ urlDecode True key, E.decodeUtf8 $ urlDecode True value)

both :: (b -> c) -> (b, b) -> (c, c)
both = join (***)

debug :: Show a => a -> a
debug a = traceShow a a
