{-
  Copyright (c) Meta Platforms, Inc. and affiliates.
  All rights reserved.

  This source code is licensed under the BSD-style license found in the
  LICENSE file in the root directory of this source tree.
-}

module Glean.Glass.Handler.Utils (
    -- * Handler wrappers: handlers should call one of these
    withRepoFile,
    withRepoLanguage,
    withSymbol,
    withRequest,

    -- * deprecated handler wrappers
    withGleanDBs,
    getLatestAttrDBs,

    -- * Utils for building handlers
    GleanBackend(..),
    backendRunHaxl,
    getGleanRepos,

    revisionSpecifierError,

    firstOrErrors,
    allOrError,

    -- * Utils for computing defs and xrefs in a document
    documentSymbolsForLanguage,
    ExtraSymbolOpts(..)
  ) where

import Control.Exception
import Control.Monad
import Control.Monad.Catch ( throwM )
import Data.Either
import qualified Data.HashMap.Strict as HashMap
import Data.Maybe
import Data.List.NonEmpty ( NonEmpty(..), nonEmpty, toList )
import Data.Text ( Text )
import qualified Data.Text as Text

import Haxl.Core as Haxl
import Haxl.DataSource.Glean (HasRepo)
import Util.Logger ( loggingAction )
import Util.STM
import qualified Logger.GleanGlass as Logger

import qualified Glean
import Glean.Haxl.Repos as Glean
import Glean.Util.Some

import Glean.Glass.Base
import Glean.Glass.Logging
import Glean.Glass.Repos
import Glean.Glass.SourceControl
import Glean.Glass.SymbolId
import Glean.Glass.Tracing
import Glean.Glass.Types
import qualified Glean.Glass.Query as Query
import qualified Glean.Glass.Query.Cxx as Cxx
import qualified Glean.Glass.Env as Glass
import Glean.Glass.XRefs ( GenXRef(..), buildGenXRefs )
import qualified Glean.Schema.Src.Types as Src
import qualified Glean.Schema.Code.Types as Code
import qualified Glean.Schema.CodemarkupTypes.Types as Code
import qualified Glean.Glass.Utils as Utils

-- | The DBs we've chosen for this request
type ChosenDBs = NonEmpty (GleanDBName, Glean.Repo)

-- | Given a query, run it on all available repos and return the first success
--   plus an explainer
firstOrErrors
  :: (HasRepo u => ReposHaxl u w (Either GlassExceptionReason a))
  -> ReposHaxl u w
      (Either (NonEmpty GlassExceptionReason) (a, QueryEachRepoLog))
firstOrErrors act = do
  results <- queryEachRepo $ do
    repo <- Glean.haxlRepo
    result <- act
    return $ (repo,) <$> result
  let (fail, success) = partitionEithers results
  return $ case success of
    (repo, x) : rest ->
      Right (x, FoundSome (repo :| fmap fst rest))
    [] -> Left $ fromMaybe (error "unreachable") $ nonEmpty fail

allOrError :: NonEmpty (Either a1 a2) -> Either a1 (NonEmpty a2)
allOrError = go (Right [])
  where
    go
      :: Either err [ok]
      -> NonEmpty (Either err ok)
      -> Either err (NonEmpty ok)
    go (Left err) _ = Left err
    go (Right _es) ((Left err) :| _) = Left err
    go (Right res) ((Right ok) :| []) =
      Right (ok :| res)
    go (Right res) ((Right ok) :| (x:xs)) =
      go (Right (ok:res)) (x :| xs)

-- | Bundle of glean db handle resources
data GleanBackend b =
  GleanBackend {
    gleanBackend :: b,
    gleanDBs :: ChosenDBs,
    tracer :: GlassTracer
  }

backendRunHaxl
  :: Glean.Backend b
  => GleanBackend b
  -> Glass.Env
  -> (forall u. ReposHaxl u w a)
  -> IO a
backendRunHaxl GleanBackend{..} Glass.Env{haxlState} haxl =
  traceSpan tracer "glean" $ do
    (state1,state2) <- Glean.initGlobalState gleanBackend
    let st = Haxl.stateSet state1 $ Haxl.stateSet state2 haxlState
    haxlEnv <- Haxl.initEnv st (Glean.Repos (fmap snd gleanDBs))
    runHaxl haxlEnv haxl

revisionSpecifierError :: Maybe Revision -> Text
revisionSpecifierError Nothing = "AnyRevision"
revisionSpecifierError (Just (Revision rev))= "Requested exactly " <> rev

-- Depending on revision provided in the options (none, exact or otherwise)
-- decide whether we'll need to choose latest, nearest or exact DB
dbChooser :: RepoName -> RequestOptions -> ChooseGleanDBs
dbChooser repo opts =
  case requestOptions_revision opts of
    Nothing -> ChooseLatest
    Just rev
      | not exact -> ChooseNearest repo rev
      | otherwise -> ChooseExactOrLatest rev
 where
 exact = requestOptions_exact_revision opts

-- | Top-level wrapper for all requests.
--
-- * Snapshots the GleanDBInfo
-- * Implements strict vs. non-strict error handling
-- * Logs the request and result
--
withRequest
  :: (LogRequest req, LogResult res)
  => Text
  -> Glass.Env
  -> req
  -> RequestOptions
  -> (GleanDBInfo -> IO (res, Maybe ErrorLogger))
  -> IO res
withRequest method env@Glass.Env{..} req opts fn = do
  dbInfo <- readTVarIO latestGleanRepos
  withStrictErrorHandling dbInfo opts $
    withLog method env opts req $
      fn dbInfo

-- | Run an action that provides a repo and maybe a language, log it
withRepoLanguage
  :: (LogRequest a, LogResult b)
  => Text
  -> Glass.Env
  -> a
  -> RepoName
  -> Maybe Language
  -> RequestOptions
  -> (  ChosenDBs
     -> GleanDBInfo
     -> Maybe Language
     -> IO (b, Maybe ErrorLogger))
  -> IO b
withRepoLanguage method env@Glass.Env{..} req repo mlanguage opts fn =
  fmap fst $ withRequest method env req opts $ \dbInfo -> do
    dbs <- getGleanRepos tracer sourceControl repoMapping dbInfo repo
      mlanguage (requestOptions_revision opts) (dbChooser repo opts) gleanDB
    withLogDB dbs $
      fn dbs dbInfo mlanguage

-- | Run an action that provides a repo and filepath, log it
withRepoFile
  :: (LogRequest a, LogResult b)
  => Text
  -> Glass.Env
  -> RequestOptions
  -> a
  -> RepoName
  -> Path
  -> (  NonEmpty (GleanDBName,Glean.Repo)
     -> GleanDBInfo
     -> Maybe Language
     -> IO (b, Maybe ErrorLogger))
  -> IO b
withRepoFile method env opts req repo file fn = do
  withRepoLanguage method env req repo (fileLanguage file) opts fn

-- | Run an action that provides a symbol id, log it
withSymbol
  :: LogResult res
  => Text
  -> Glass.Env
  -> RequestOptions
  -> SymbolId
  -> (  NonEmpty (GleanDBName, Glean.Repo)
     -> GleanDBInfo
     -> (RepoName, Language, [Text], [SymbolFilter])
     -> IO (res, Maybe ErrorLogger))
  -> IO res
withSymbol method env@Glass.Env{..} opts sym fn =
  fmap fst $ withRequest method env sym opts $ \dbInfo ->
    case symbolTokens sym of
      Left err -> throwM $ ServerException err
      Right req@(repo, lang, _toks, _filters) -> do
        dbs <- getGleanRepos tracer sourceControl repoMapping dbInfo repo
          (Just lang) (requestOptions_revision opts)
          (dbChooser repo opts) gleanDB
        withLogDB dbs $ fn dbs dbInfo req

withStrictErrorHandling
  :: GleanDBInfo
  -> RequestOptions
  -> IO (res, Maybe ErrorLogger)
  -> IO res
withStrictErrorHandling dbInfo opts action = do
  (res, merr) <- action
  case merr of
    Just err
      | requestOptions_strict opts
      , not $ null $ errorTy err
      -> do
          let getFirstRevision repo =
                case HashMap.lookup repo (scmRevisions dbInfo) of
                  Just m | rev : _ <- HashMap.elems m ->
                    Just (scmRevision rev)
                  _ -> Nothing
          throwM $ GlassException
            (errorTy err)
            (mapMaybe getFirstRevision (errorGleanRepo err))
    _ -> return res

-- | Perform logging for a request. Logs the request and the response
-- or errors that were thrown.
withLog
  :: (LogRequest req, LogResult res)
  => Text
  -> Glass.Env
  -> RequestOptions
  -> req
  -> IO res
  -> IO res
withLog cmd env opts req action = do
  let requestLogs =
        Logger.setMethod cmd <>
        logRequest req <>
        logRequest opts
  loggingAction
    (Logger.runLog (Glass.logger env) . (requestLogs <>))
    logResult
    action

withLogDB
  :: ChosenDBs
  -> IO (b, Maybe ErrorLogger)
  -> IO ((b, ChosenDBs), Maybe ErrorLogger)
withLogDB dbs act = do
  (b, merr) <- act
  return ((b,dbs), merr)

-- | Given an SCS repo name, and a candidate path, find latest Glean dbs or
-- throw. Returns the chosen db name and Glean repo handles.
-- If a Glean.Repo is given, use it instead.
getGleanRepos
  :: GlassTracer
  -> Some SourceControl
  -> RepoMapping
  -> GleanDBInfo
  -> RepoName
  -> Maybe Language
  -> Maybe Revision
  -> ChooseGleanDBs
  -> Maybe Glean.Repo
  -> IO ChosenDBs
getGleanRepos tracer scm repoMapping dbInfo
  scsrepo mlanguage revision chooser mGleanDB =
    case mGleanDB of
      Nothing -> do
        gleanDBs <- fromSCSRepo repoMapping scsrepo branchesFilter mlanguage
        case gleanDBs of
          [] ->  throwIO $ ServerException $ "No repository found for: " <>
            unRepoName scsrepo <>
              maybe "" (\x -> " (" <> toShortCode x <> ")") mlanguage
          (x:xs) ->
            getSpecificGleanDBs tracer scm dbInfo chooser (x :| xs)
      Just gleanDB@Glean.Repo{repo_name} ->
        return ((GleanDBName repo_name, gleanDB) :| [])
  where
    branchesFilter :: Maybe (Text -> IO Bool)
    branchesFilter = fmap (isDescendantBranch scm scsrepo) revision

-- | If you already know the set of dbs you need, just get them.
getSpecificGleanDBs
  :: GlassTracer
  -> Some SourceControl
  -> GleanDBInfo
  -> ChooseGleanDBs
  -> NonEmpty GleanDBName
  -> IO ChosenDBs
getSpecificGleanDBs tracer scm dbInfo chooser gleanDBNames = do
  dbs <- chooseGleanDBs tracer scm dbInfo chooser (toList gleanDBNames)
  case dbs of
    [] -> throwIO $ ServerException $ "No Glean dbs found for: " <>
            Text.intercalate ", " (map unGleanDBName $ toList gleanDBNames)
    db:dbs -> return (db :| dbs)

-- | Legacy API that (a) doesn't do strict error handling and (b) chooses
-- DBs by name, not repo. TODO: clean this up
withGleanDBs
  :: (LogRequest req, LogResult res)
  => Text
  -> Glass.Env
  -> RequestOptions
  -> req
  -> RepoName
  -> NonEmpty GleanDBName
  -> (ChosenDBs -> GleanDBInfo -> IO res)
  -> IO res
withGleanDBs method env@Glass.Env{..} opts req repo dbNames fn = do
  dbInfo <- readTVarIO latestGleanRepos
  dbs <- getSpecificGleanDBs tracer sourceControl dbInfo (dbChooser repo opts) dbNames
  fmap fst $ withLog method env opts req $
    (,dbs) <$> fn dbs dbInfo

-- | Get glean db for an attribute type (always choose the latest)
getLatestAttrDBs
  :: GlassTracer
  -> Some SourceControl
  -> RepoMapping
  -> GleanDBInfo
  -> RepoName
  -> IO [(Glean.Repo, GleanDBAttrName)]
getLatestAttrDBs tracer scm repoMapping dbInfo repo =
  fmap catMaybes $ forM (attrDBsForRepo repoMapping repo) $
    \attrDBName -> do
      dbs <- chooseGleanDBs tracer scm dbInfo ChooseLatest
        [gleanAttrDBName attrDBName]
      return $ case dbs of
        [] -> Nothing
        db:_ -> Just (snd db, attrDBName)

-- | Args that modify the shape of the output
data ExtraSymbolOpts = ExtraSymbolOpts {
  oIncludeRefs :: !Bool,  -- ^ include references?
  oIncludeXlangRefs :: !Bool,  -- ^ include xlang references?
  oLineRange :: Maybe [LineRange] -- ^ restrict to specifc range
}

type Defns = [(Code.Location,Code.Entity)]

-- | Which fileEntityLocations and fileEntityXRefLocation implementations to use
documentSymbolsForLanguage
  :: Maybe Int
  -> Maybe Language
  -> ExtraSymbolOpts
  -> Glean.IdOf Src.File
  -> Glean.RepoHaxl u w ([GenXRef], Defns, Bool)

-- For Cpp, we need to do a bit of client-side processing
documentSymbolsForLanguage
  mlimit (Just Language_Cpp) opts fileId = Cxx.documentSymbolsForCxx
    mlimit (oIncludeRefs opts) (oIncludeXlangRefs opts) fileId

-- For everyone else, we just query the generic codemarkup predicates
documentSymbolsForLanguage mlimit _ ExtraSymbolOpts{..} fileId = do
  (xrefs, trunc1) <- if oIncludeRefs
    then Utils.searchRecursiveWithLimit mlimit $
      Query.fileEntityXRefsGenEntities fileId oIncludeXlangRefs
    else return ([], False)
  (defns, trunc2) <- Utils.searchRecursiveWithLimit mlimit $
    Query.fileEntityLocations fileId
  return (mapMaybe buildGenXRefs xrefs, defns, trunc1 || trunc2)
