{-
  Copyright (c) Meta Platforms, Inc. and affiliates.
  All rights reserved.

  This source code is licensed under the BSD-style license found in the
  LICENSE file in the root directory of this source tree.
-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Glean.Glass.Logging
  (
  -- * classes for convenient typed logging
    LogResult(..)
  , LogRequest(..)
  , LogError(..)

  -- * some types
  , QueryEachRepoLog(..)
  , ErrorText(..)
  , ErrorLogger(..)
  , AttrDBsLog(..)
  , AttrStatsLog(..)
  , errorText
  , errorsText

  ) where

import Control.Applicative ((<|>))
import Data.Coerce
import Data.List.Extra (nubOrd)
import Data.List.NonEmpty(NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Function (on)
import Util.Text (textShow)

import Util.Logger (ActionLog(..))
import Logger.GleanGlass (GleanGlassLogger)
import qualified Logger.GleanGlass as Logger

import Glean (Repo(..), repoToText)
import Glean.Glass.Types
import Glean.Glass.SnapshotBackend ( SnapshotStatus(..) )
import qualified Thrift.Protocol.JSON as Thrift

instance ActionLog GleanGlassLogger where
  successLog = Logger.setSuccess True
  failureLog ex = mconcat
    [ Logger.setSuccess False
    , Logger.setError (textShow ex)
    ]
  timeLog = Logger.setTimeElapsedUs . floor . (* 1000) . (* 1000)
  allocLog = Logger.setAllocatedBytes . fromIntegral

class LogRequest a where
  logRequest :: a -> GleanGlassLogger

instance LogRequest a => LogRequest (Maybe a) where
  logRequest = maybe mempty logRequest

instance LogRequest RequestOptions where
  logRequest RequestOptions{..} =
    maybe mempty (Logger.setRevision . unRevision) requestOptions_revision <>
    maybe mempty (Logger.setLimit . fromIntegral) requestOptions_limit <>
    Logger.setExactRevision requestOptions_exact_revision <>
    Logger.setMatchingRevision requestOptions_matching_revision <>
    Logger.setContentCheck requestOptions_content_check <>
    logRequest requestOptions_feature_flags <>
    logRequest requestOptions_attribute_opts

instance LogRequest AttributeOptions where
  logRequest AttributeOptions{..} =
    Logger.setAttributeOptions $ textShow $ Thrift.serializeJSON AttributeOptions{..}

instance LogRequest FeatureFlags where
  logRequest FeatureFlags{} = mempty

instance LogRequest DocumentSymbolsRequest where
  logRequest = logDocumentSymbolsRequestSG Logger.setFilepath Logger.setRepo

instance LogRequest SymbolId where
  logRequest = logSymbolSG Logger.setSymbol

instance LogRequest USRHash where
  logRequest (USRHash hash) = logSymbolSG Logger.setSymbol (SymbolId hash)

instance LogRequest USR where
  logRequest (USR usr) = logSymbolSG Logger.setSymbol (SymbolId usr)

instance LogRequest USRToDefinitionRequest where
  logRequest = logUSRToDefinitionRequestSG Logger.setSymbol Logger.setRepo

instance LogRequest SymbolPath where
  logRequest = logSymbolPathSG Logger.setFilepath Logger.setRepo

instance LogRequest SymbolSearchRequest where
  logRequest = logSymbolSearchRequestSG Logger.setSymbol Logger.setRepo

instance LogRequest FileIncludeLocationRequest where
  logRequest FileIncludeLocationRequest{..} =
    Logger.setFilepath (unPath fileIncludeLocationRequest_filepath) <>
      Logger.setRepo (unRepoName fileIncludeLocationRequest_repository)

class LogResult a where
  logResult :: a -> GleanGlassLogger

instance LogResult () where
  logResult = mempty

instance LogResult GleanGlassLogger where
  logResult = id

instance LogResult a => LogResult (Maybe a) where
  logResult = maybe mempty logResult

instance (LogResult a, LogResult b) => LogResult (a,b) where
  logResult (a,b) = logResult a <> logResult b

instance (LogResult a, LogResult b, LogResult c) => LogResult (a,b,c) where
  logResult (a,b,c) = logResult a <> logResult b <> logResult c

instance (LogResult a, LogResult b, LogResult c,  LogResult d)
  => LogResult (a,b,c,d) where
    logResult (a,b,c,d) =
      logResult a <> logResult b <> logResult c  <> logResult d

instance LogResult DocumentSymbolListXResult  where
  logResult DocumentSymbolListXResult{..} =
    Logger.setTruncated documentSymbolListXResult_truncated <>
    Logger.setItemCount (length documentSymbolListXResult_references +
      length documentSymbolListXResult_definitions) <>
    Logger.setRevisionUsed (coerce documentSymbolListXResult_revision) <>
    maybe mempty Logger.setContentMatch documentSymbolListXResult_content_match

instance LogResult FileIncludeLocationResults where
  logResult FileIncludeLocationResults{..} =
    Logger.setItemCount (sum
       (map (length . fileIncludeXRef_includes)
          (unXRefFileList fileIncludeLocationResults_references)
       ))

instance LogResult SnapshotStatus where
  logResult st = logSnapshotStatus st

data QueryEachRepoLog
  = FoundNone
  | FoundSome (NonEmpty Glean.Repo)
  | QueryEachRepoUnrequested

instance LogResult QueryEachRepoLog where
  logResult glog = case glog of
    FoundSome (one :| more) ->
      Logger.setDbUsedName (Glean.repo_name one) <>
      Logger.setDbUsedInstance (Glean.repo_hash one) <>
      if null more
        then mempty
        else Logger.setRepoOther (map Glean.repo_name more)
    _ -> mempty

instance LogResult DocumentSymbolIndex where
  logResult DocumentSymbolIndex{..} =
    Logger.setItemCount (fromIntegral documentSymbolIndex_size)
        <> Logger.setTruncated documentSymbolIndex_truncated
        <> Logger.setRevisionUsed (coerce documentSymbolIndex_revision)
        <> maybe mempty Logger.setContentMatch documentSymbolIndex_content_match

instance LogResult Range where
  logResult _ = mempty

instance LogResult [LocationRange] where
  logResult xs = Logger.setItemCount (length xs)

instance LogResult LocationRange where
  logResult LocationRange{..} = mconcat
    [ Logger.setItemCount 1
    , Logger.setRepo $ unRepoName locationRange_repository
    ]

instance LogResult SymbolLocation where
  logResult SymbolLocation{..} = logResult symbolLocation_location
      <> Logger.setRevisionUsed (coerce symbolLocation_revision)

instance LogResult SymbolDescription where
  logResult SymbolDescription{..} =
    logResult symbolDescription_location <>
    logResult symbolDescription_sym <>
    Logger.setItemCount 1

instance LogResult [SymbolResolution] where
  logResult xs = Logger.setItemCount (length xs)

instance LogResult SymbolResolutionFailure where
  logResult SymbolResolutionFailure{..} =
      Logger.setInternalError (errorText symbolResolutionFailure_reason)

instance LogResult SymbolPath where
  logResult SymbolPath{..} =
    Logger.setRepo (unRepoName symbolPath_repository)

instance LogResult SymbolId where
  logResult sym = logSymbolSG Logger.setSymbol sym

instance LogResult [SymbolId] where
  logResult xs = Logger.setItemCount (length xs)

instance LogResult [(SymbolResult, Maybe SymbolDescription)] where
  logResult rs = Logger.setItemCount (length rs)

instance LogResult SymbolSearchResult where
  logResult SymbolSearchResult{..} =
    Logger.setItemCount (length symbolSearchResult_symbols)

instance LogResult SearchRelatedResult where
  logResult SearchRelatedResult{..} =
    logResult searchRelatedResult_edges

instance LogResult RelatedNeighborhoodResult where
  logResult RelatedNeighborhoodResult{..} =
    Logger.setItemCount
      (length relatedNeighborhoodResult_childrenContained +
        length relatedNeighborhoodResult_childrenExtended +
        length relatedNeighborhoodResult_containsParents +
        length relatedNeighborhoodResult_parentsExtended +
        sum (map (\x -> 1 + length (inheritedSymbols_provides x))
              relatedNeighborhoodResult_inheritedSymbols
            )
      )

instance LogResult USRSymbolDefinition where
  logResult USRSymbolDefinition{..} =
    logResult uSRSymbolDefinition_location <>
    Logger.setItemCount 1


instance LogResult USRSymbolReference  where
  logResult USRSymbolReference{..} =
    logResult uSRSymbolReference_location <>
    Logger.setItemCount 1

instance LogResult [USRSymbolReference] where
  logResult xs = Logger.setItemCount (length xs)

instance LogResult [RelatedSymbols] where
  logResult edges = Logger.setItemCount (length edges)

newtype AttrDBsLog = AttrDBsLog { attrDb :: Glean.Repo }
instance LogResult [AttrDBsLog] where
  logResult logs = Logger.setAttributeDbs (map (Glean.repoToText . attrDb) logs)

newtype AttrStatsLog = AttrStatsLog { stats :: Text }
instance LogResult [AttrStatsLog] where
  logResult logs = Logger.setDynamicAttributeStats (map stats logs)

--
-- | Intern error logging
--

newtype ErrorText = ErrorText Text

errorText :: GlassExceptionReason -> Text
errorText e = case e of
  GlassExceptionReason_noSrcFileFact t -> t
  GlassExceptionReason_noSrcFileLinesFact t -> t
  GlassExceptionReason_notIndexedFile t -> t
  GlassExceptionReason_entitySearchFail t -> t
  GlassExceptionReason_entityNotSupported t -> t
  GlassExceptionReason_attributesError t -> t
  GlassExceptionReason_exactRevisionNotAvailable t -> t
  GlassExceptionReason_matchingRevisionNotAvailable t -> t
  GlassExceptionReason_EMPTY -> ""

errorsText :: NonEmpty GlassExceptionReason -> Text
errorsText errs =
  Text.unlines $ "Multiple errors:": map
    (("  " <>) . errorText)
    (NE.toList errs)

data ErrorLogger = ErrorLogger
  { errorTy :: ![GlassExceptionReason]
  , errorGleanRepo :: ![Glean.Repo]
    -- ^ The repo(s) in which the error(s) occurred.
  }

instance Semigroup ErrorLogger where
  e1 <> e2 = ErrorLogger
    { errorTy = errorTy e1 <|> errorTy e2
    , errorGleanRepo = errorGleanRepo e1 <> errorGleanRepo e2
    }

instance Monoid ErrorLogger where
  mempty = ErrorLogger mempty []

instance LogResult ErrorLogger where
  logResult ErrorLogger{..} =
    case nubOrd errorTy of
      [] -> mempty
      [e] ->
        Logger.setInternalError (errorText e) <>
        Logger.setInternalErrorType (case e of
          GlassExceptionReason_noSrcFileFact{} -> "NoSrcFileFact"
          GlassExceptionReason_noSrcFileLinesFact{} -> "NoSrcFileLinesFact"
          GlassExceptionReason_entitySearchFail{} -> "EntitySearchFail"
          GlassExceptionReason_entityNotSupported{} -> "EntityNotSupported"
          GlassExceptionReason_attributesError{} -> "AttributesError"
          GlassExceptionReason_notIndexedFile{} -> "NotIndexedFile"
          GlassExceptionReason_exactRevisionNotAvailable{} ->
            "ExactRevisionNotAvaiable"
          GlassExceptionReason_matchingRevisionNotAvailable{} ->
            "MatchingRevisionNotAvailable"
          GlassExceptionReason_EMPTY{} -> "EMPTY"
        )
      (e:es) ->
        Logger.setInternalError (errorsText (e :| es)) <>
        Logger.setInternalErrorType "AggregateError"

class LogError a where
  logError :: a -> ErrorLogger

instance LogError GlassExceptionReason where
  logError e = ErrorLogger [e] []

instance LogError (NonEmpty GlassExceptionReason) where
  logError (e :| []) = logError e
  logError errors = ErrorLogger (NE.toList errors) []

instance LogError Glean.Repo where
  logError x =
    ErrorLogger [] [x]

instance LogError (NonEmpty (a, Glean.Repo)) where
  logError = logError . NE.map snd

instance LogError (NonEmpty Glean.Repo) where
  logError (repo :| []) = logError repo
  logError rs0 = ErrorLogger [] (NE.toList rs)
    where
    rs = NE.sortBy (compare `on` Glean.repo_name) rs0

--
-- Lift log accessors generically over Glass types
--

logSymbolSG :: Semigroup a => (Text -> a)
  -> SymbolId -> a
logSymbolSG f (SymbolId s) = f s

logSymbolPathSG :: Semigroup a => (Text -> a) -> (Text -> a)
  -> SymbolPath -> a
logSymbolPathSG f g SymbolPath{..} =
    f (unPath symbolPath_filepath) <>
      g (unRepoName symbolPath_repository)

logDocumentSymbolsRequestSG :: Semigroup a => (Text -> a) -> (Text -> a)
  -> DocumentSymbolsRequest  -> a
logDocumentSymbolsRequestSG f g DocumentSymbolsRequest{..} =
    f (unPath documentSymbolsRequest_filepath) <>
    g (unRepoName documentSymbolsRequest_repository)

logSymbolSearchRequestSG :: Semigroup a => (Text -> a) -> (Text -> a)
  -> SymbolSearchRequest -> a
logSymbolSearchRequestSG logQuery logRepo SymbolSearchRequest{..} =
  case repo of
    Nothing -> logQuery symbolSearchRequest_name
    Just r -> logRepo r <> logQuery symbolSearchRequest_name
  where
    repo = unRepoName <$> symbolSearchRequest_repo_name

logUSRToDefinitionRequestSG ::
  Semigroup a =>
  (Text -> a) ->
  (Text -> a) ->
  USRToDefinitionRequest ->
  a
logUSRToDefinitionRequestSG
    logQuery
    logRepo
    (USRToDefinitionRequest usrr repo_name) =
  case repo of
    Nothing -> logQuery usr
    Just r -> logRepo r <> logQuery usr
 where
  usr = unUSR usrr
  repo = unRepoName <$> repo_name

logSnapshotStatus :: SnapshotStatus -> GleanGlassLogger
logSnapshotStatus st = case st of
  Unrequested -> mempty
  DbError -> Logger.setSnapshot "DB error"
  InternalError -> Logger.setSnapshot "Internal error"
  Timeout -> Logger.setSnapshot "Timeout"
  NotFound -> Logger.setSnapshot  "Not found"
  ExactMatch -> Logger.setSnapshot  "Exact"
  CompatibleMatch -> Logger.setSnapshot  "Matching"
  Ignored -> Logger.setSnapshot  "Ignored"
  Latest -> Logger.setSnapshot "Latest"
