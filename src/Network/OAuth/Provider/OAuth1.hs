{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE ViewPatterns          #-}

-- | This module provides the basic building blocks to build applications with OAuth 1.0 cababilities.
-- OAuth 1.0 is specified by <http://tools.ietf.org/html/rfc5849 RFC 5849>.
--
-- "oauth-provider" implements the /One Legged/, /Two Legged/, and /Three Legged/ flows described
-- in <https://github.com/Mashape/mashape-oauth/blob/master/FLOWS.md>.
module Network.OAuth.Provider.OAuth1
    (
      authenticated
    -- * One-legged Flow
    , oneLegged
    -- * Two-legged Flow
    , twoLeggedRequestTokenRequest
    , twoLeggedAccessTokenRequest
    -- * Three-legged Flow
    , threeLeggedRequestTokenRequest
    , threeLeggedAccessTokenRequest
    ) where

import           Control.Error.Util         (note)
import           Control.Monad              (mfilter, unless)
import           Control.Monad.Trans.Class  (lift)
import           Control.Monad.Trans.Either (EitherT (..))
import           Data.Attoparsec.Char8      (decimal, parseOnly)
import           Data.ByteString            (ByteString)
import           Data.Either.Combinators    (mapLeft)
import           Data.Functor               ((<$>))
import           Data.Maybe                 (fromMaybe)
import           Data.Monoid                ((<>))
import           Network.HTTP.Types         (hContentType, ok200)

import qualified Data.ByteString            as B
import qualified Data.Text.Encoding         as E

import           Network.OAuth.Provider.OAuth1.Internal
import           Network.OAuth.Provider.OAuth1.Types

-- | Checks that the request is signed by the final consumer-accesstoken secrets.
authenticated :: Monad m => OAuthM m OAuthParams
authenticated = do
    OAuthConfig {..} <- getOAuthConfig
    processOAuthRequest (bsSecretLookup AccessTokenKey cfgAccessTokenSecretLookup)

-- | The one legged flow requires an empty /oauth_token/ parameter.
oneLegged :: Monad m => OAuthM m OAuthParams
oneLegged = processOAuthRequest emptyTokenLookup

-- | Handles the first step of the two legged OAuth flow and produces a
-- 'Response' with a token/secret pair generated by calling
-- 'cfgTokenGenerator' 'RequestToken'.
twoLeggedRequestTokenRequest :: Monad m => OAuthM m OAuthResponse
twoLeggedRequestTokenRequest = do
    OAuthConfig {..} <- getOAuthConfig
    twoLegged emptyTokenLookup (cfgTokenGenerator RequestToken)

-- | Handles the second step of the two legged OAuth flow and produces a
-- 'Response' with a token/secret pair generated by calling
-- 'cfgTokenGenerator' 'AccessToken'.
twoLeggedAccessTokenRequest :: Monad m => OAuthM m OAuthResponse
twoLeggedAccessTokenRequest = do
    OAuthConfig {..} <- getOAuthConfig
    twoLegged (bsSecretLookup RequestTokenKey cfgRequestTokenSecretLookup)
              (cfgTokenGenerator AccessToken)

twoLegged :: Monad m => SecretLookup Token m -> (ConsumerKey -> m (Token, Secret)) -> OAuthM m OAuthResponse
twoLegged tokenLookup secretCreation = do
    responseString <- processTokenCreationRequest tokenLookup secretCreation noProcessing
    return $ mkResponse200 responseString
  where
    noProcessing = const (return ())

-- | Handles the first step of the three legged OAuth flow and produces a
-- 'Response' with a token/secret pair generated by calling
-- 'cfgTokenGenerate' 'RequestToken'.
threeLeggedRequestTokenRequest :: Monad m => OAuthM m OAuthResponse
threeLeggedRequestTokenRequest = do
    OAuthConfig {..} <- getOAuthConfig
    responseParams <- processTokenCreationRequest emptyTokenLookup
        (cfgTokenGenerator RequestToken)
        (storeCallback cfgCallbackStore)
    return $ mkResponse200 $ ("oauth_callback_confirmed", "true") : responseParams
  where
    storeCallback cbStore OAuthParams {..} = maybe missingCallback (lift . cbStore (opConsumerKey, opToken)) opCallback
    missingCallback = oauthEither . Left $ MissingParameter "oauth_callback"

-- | Handles the third step of the three legged OAuth flow. The request is
-- expected to provide the 'Verifier' that was associated with the 'Request's
-- 'ConsumerKey' and 'Token' in step two.
threeLeggedAccessTokenRequest :: Monad m => OAuthM m OAuthResponse
threeLeggedAccessTokenRequest = do
    OAuthConfig {..} <- getOAuthConfig
    responseParams <- processTokenCreationRequest
        (bsSecretLookup RequestTokenKey cfgRequestTokenSecretLookup)
        (cfgTokenGenerator AccessToken) (verifierCheck cfgVerifierLookup)
    return $ mkResponse200 responseParams
  where
    verifierCheck verifierLookup params = do
        storedVerifier <- lift $ verifierLookup (opConsumerKey params, opToken params)
        case opVerifier params of
            Just ((==) storedVerifier -> True) -> oauthEither $ Right ()
            Just wrongVerifier                 -> oauthEither $ Left (InvalidVerifier wrongVerifier)
            Nothing                            -> oauthEither $ Left (MissingParameter "oauth_verifier")

processOAuthRequest :: Monad m => SecretLookup Token m -> OAuthM m OAuthParams
processOAuthRequest tokenLookup = do
    oauth <- validateRequest
    OAuthConfig {..} <- getOAuthConfig
    _ <- verifyOAuthSignature cfgConsumerSecretLookup tokenLookup oauth
    _ <- OAuthM . EitherT . lift $ do
        maybeError <- cfgNonceTimestampCheck $ oauthParams oauth
        return $ maybe (Right ()) Left  maybeError
    return $ oauthParams oauth

processTokenCreationRequest :: Monad m =>
    SecretLookup Token m
    -> (ConsumerKey -> m (Token, Secret)) -> (OAuthParams -> OAuthM m ())
    -> OAuthM m [(ByteString, ByteString)]
processTokenCreationRequest tokenLookup secretCreation customProcessing = do
    params <- processOAuthRequest tokenLookup
    _      <- customProcessing params
    (Token token, Secret secret) <- lift $ secretCreation $ opConsumerKey params
    return [("oauth_token", token), ("oauth_token_secret", secret)]

validateRequest :: Monad m => OAuthM m OAuthState
validateRequest = do
    request <- getOAuthRequest
    (oauths, rest) <- splitOAuthParams
    url <- oauthEither $ generateNormUrl request

    let getM name = mfilter ( /= "") $ E.encodeUtf8 <$> lookup name oauths
        getE name = note (MissingParameter name) $ getM name
        getOrEmpty name = fromMaybe "" $ getM name
    oauth  <- oauthEither $ do
        signMeth <- getE "oauth_signature_method" >>= extractSignatureMethod
        signature <- Signature <$> getE "oauth_signature"
        consKey <- ConsumerKey <$> getE "oauth_consumer_key"
        timestamp <- maybe (Right Nothing) (fmap Just) (parseTS <$> getM "oauth_timestamp")
        return $ OAuthParams
            consKey
            (Token $ getOrEmpty "oauth_token")
            signMeth
            (Callback <$> getM "oauth_callback")
            (Verifier <$> getM "oauth_verifier")
            signature
            (Nonce <$> getM "oauth_nonce")
            timestamp
    return OAuthState { oauthRawParams = oauths, reqParams = rest, reqUrl = url
                      , reqMethod = reqRequestMethod request, oauthParams = oauth }
  where
    parseTS = mapLeft (const InvalidTimestamp) . parseOnly decimal



mkResponse200 :: [(ByteString, ByteString)] -> OAuthResponse
mkResponse200 params = OAuthResponse ok200 [(hContentType, "application/x-www-form-urlencoded")] body
  where
    body = B.intercalate "&" $ fmap paramString params
    paramString (a,b) = B.concat [a, "=", b]


verifyOAuthSignature :: Monad m =>
    SecretLookup ConsumerKey m
    -> SecretLookup Token m
    -> OAuthState
    -> OAuthM m ()
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
    wrapped f = OAuthM . EitherT . lift . f



