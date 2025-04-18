{-
  Copyright (c) Meta Platforms, Inc. and affiliates.
  All rights reserved.

  This source code is licensed under the BSD-style license found in the
  LICENSE file in the root directory of this source tree.
-}

{-# LANGUAGE TemplateHaskell, QuasiQuotes, DeriveGeneric #-}
-- | Utilities for writing data to Glean
module Glean.Write
  ( fileToBatches
  , parseRef
  , parseJsonFactBatches
  ,schemaIdToOpts) where

import Control.Exception (ErrorCall(ErrorCall), throwIO)
import Control.Monad.Extra
import Data.Aeson
import qualified Data.Aeson.Types as Aeson
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Maybe
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Vector as Vector
import Foreign(Ptr)
import Foreign.C(CString, CChar, CLong(..))

import Mangle.TH
import Foreign.CPP.Dynamic (Dynamic, callJSONParserFFI)
import Util.String.Quasi

import Glean.Types hiding (Value)
import Glean.Schema.Util
import System.FilePath (takeExtension)
import qualified System.Process.ByteString as BS
import System.Exit (ExitCode(ExitSuccess))
import Control.Applicative ((<|>))
import Data.Either (partitionEithers)

$(mangle
  [s|
    folly::dynamic* facebook::glean::cpp::parseJSONFacts(
        const char*, int64_t, char **)
  |] [d|
    foreign import ccall safe c_parseJsonFacts
      :: CString -> CLong -> Ptr (Ptr CChar) -> IO (Ptr Dynamic)
  |])

newtype ParseJsonFactBatchForWriteServer = ParseJsonFactBatchForWriteServer
  {getBatch :: JsonItem}
instance FromJSON ParseJsonFactBatchForWriteServer where
  parseJSON =
    fmap ParseJsonFactBatchForWriteServer <$>
      parseJsonFactBatchGen (withText "fact" $ return . Text.encodeUtf8)

fileToBatches :: FilePath -> IO ([JsonFactBatch], Maybe SchemaId)
fileToBatches file = do
  bs <- if takeExtension file == ".zst" then do
    (exit, bs, err) <- BS.readProcessWithExitCode "zstd" [file,"-d","-c"] ""
    when (exit /= ExitSuccess) $
      throwIO $ ErrorCall $ file ++ ": " ++ show err
    return bs
    else B.readFile file
  r <- Foreign.CPP.Dynamic.callJSONParserFFI c_parseJsonFacts bs
  case r of
    Right val -> case Aeson.parse parseJSON val of
      Aeson.Error str -> throwIO $ ErrorCall $ file ++ ": " ++ str
      Aeson.Success x -> return $ jsonItemsToPair $ map getBatch x
    Left err -> throwIO $ ErrorCall $ file ++ ": " ++ Text.unpack err

parsePredicate :: Value -> Aeson.Parser PredicateRef
parsePredicate = withText "predicate" $ \txt -> do
  let SourceRef pred mbVersion = parseRef txt
  return (PredicateRef pred (fromMaybe 1 mbVersion))

parsePredicateRef :: Value -> Aeson.Parser PredicateRef
parsePredicateRef = withObject "predicate ref" $ \obj ->
  PredicateRef
    <$> obj .: "name"
    <*> obj .: "version"

parseFact :: Value -> Aeson.Parser ByteString
parseFact = withObject "fact" $ \obj -> return (LB.toStrict (encode obj))

-- | Given a fact parser, returns a 'JsonFactBatch' parser
parseJsonFactBatchGen
  :: (Value -> Aeson.Parser Json) -> Value -> Aeson.Parser JsonItem
parseJsonFactBatchGen parseFact = withObject "JsonFactBatch" $ \v ->
  fmap JsonItemBatch (JsonFactBatch
    <$> Aeson.explicitParseField parsePred v "predicate"
    <*> Aeson.explicitParseField parseFacts v "facts"
    <*> fmap (fmap Text.encodeUtf8) (v .:? "unit"))
  <|>
  (JsonItemSchemaId
    <$> fmap SchemaId (v .: "schema_id"))
  where
    parsePred v = parsePredicate v `mplus` parsePredicateRef v
    parseFacts = withArray "facts" (mapM parseFact . Vector.toList)

-- | Parser that expects facts to be JSON objects
parseJsonFactBatches :: Value -> Aeson.Parser ([JsonFactBatch], Maybe SchemaId)
parseJsonFactBatches = withArray "JsonFactBatch" $ \vec ->
  jsonItemsToPair <$> mapM (parseJsonFactBatchGen parseFact) (Vector.toList vec)

data JsonItem = JsonItemBatch JsonFactBatch | JsonItemSchemaId SchemaId

jsonItemsToPair :: [JsonItem] -> ([JsonFactBatch], Maybe SchemaId)
jsonItemsToPair items = (batches, listToMaybe schemas)
 where
  (batches, schemas) = partitionEithers (map toEither items)
  toEither (JsonItemBatch item) = Left item
  toEither (JsonItemSchemaId schema_id) = Right schema_id

schemaIdToOpts :: Maybe SchemaId -> Maybe SendJsonBatchOptions
schemaIdToOpts schema_id = case schema_id of
  Nothing -> Nothing
  Just s -> Just SendJsonBatchOptions {
      sendJsonBatchOptions_schema_id = Just s,
      sendJsonBatchOptions_no_base64_binary = False
    }
