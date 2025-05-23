{-
  Copyright (c) Meta Platforms, Inc. and affiliates.
  All rights reserved.

  This source code is licensed under the BSD-style license found in the
  LICENSE file in the root directory of this source tree.
-}

{-

Generic indexer for LSIF. Supply name of lsif binary in $PATH to run
predicates for typescript.

-}

{-# LANGUAGE OverloadedStrings #-}

module Glean.LSIF.Driver (
    LsifIndexerParams(..),
    processLSIF,
    runIndexer,

    -- writing
    writeJSON
 ) where

import Control.Exception ( throwIO, ErrorCall(ErrorCall) )
import Control.Monad.State.Strict
import Data.Text ( Text )
import Data.List ( intersperse )
import System.Directory ( getHomeDirectory, withCurrentDirectory, makeAbsolute )
import System.FilePath
    ( (</>), dropTrailingPathSeparator, takeBaseName )
import System.IO ( openFile, IOMode(WriteMode), hClose )
import System.IO.Temp ( withSystemTempDirectory )
import System.Process ( callProcess, callCommand )
import Text.Printf ( printf )
import Util.Log ( logInfo )
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Char8 as Strict
import qualified Data.ByteString.Lazy.Char8 as Lazy
import qualified Data.Vector as V
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Text as Text

import qualified Foreign.CPP.Dynamic

import qualified Data.LSIF.Angle as LSIF

data LsifIndexerParams = LsifIndexerParams
  { lsifBinary :: FilePath
  , lsifArgs :: FilePath -> [String]
  , lsifRoot :: FilePath
  , lsifStdout :: Bool
  }

-- | Run an LSIF indexer, and convert to a Glean's lsif.angle database
-- foramt, returning a single JSON value that can be sent to the Glean server
runIndexer :: LsifIndexerParams -> IO Aeson.Value
runIndexer params@LsifIndexerParams{..} = do
  repoDir <- makeAbsolute lsifRoot -- save this before we switch to tmp
  withSystemTempDirectory "glean-lsif" $ \lsifDir -> do
    let lsifFile = lsifDir </> "index.lsif"
    runLSIFIndexer params { lsifRoot = repoDir } lsifFile
    processLSIF repoDir lsifFile

-- | Run a generic lsif-producing indexer on a repository,
-- put lsif dump output into outputFile
runLSIFIndexer :: LsifIndexerParams -> FilePath -> IO ()
runLSIFIndexer LsifIndexerParams{..} outputFile =
  withCurrentDirectory lsifRoot $ do
    logInfo $ printf "Indexing %s with %s" (takeBaseName lsifRoot) lsifBinary
    let args = lsifArgs outputFile
    if lsifStdout
      then callCommand $
        printf "%s %s > %s" lsifBinary (unwords args) outputFile
      else callProcess lsifBinary args

-- | Convert an lsif json dump into Glean lsif.angle JSON object
processLSIF :: FilePath -> FilePath -> IO Aeson.Value
processLSIF repoDir lsifFile = do
  logInfo $ "Using LSIF from " <> lsifFile
  toLsifAngle repoDir =<< Lazy.readFile lsifFile

-- | Write json to file
writeJSON :: FilePath -> Aeson.Value -> IO ()
writeJSON outFile json = do
  logInfo $ "Writing Angle facts to " <> outFile
  case json of
    Aeson.Array facts -> encodeChunks outFile facts
    _ -> Aeson.encodeFile outFile json

-- Uses less memory if we do this piece-wise
encodeChunks :: FilePath -> V.Vector Aeson.Value -> IO ()
encodeChunks file vs = do
  handle <- openFile file WriteMode
  Lazy.hPut handle "["
  mapM_ (writeChunk handle) $
          intersperse (Right ",") (map Left (V.toList vs))
  Lazy.hPut handle "]\n"
  hClose handle
  where
    writeChunk handle (Left c) = Lazy.hPut handle (Aeson.encode c)
    writeChunk handle (Right s) = Lazy.hPut handle (s <> "\n")

-- Get some likely prefix paths to drop from indexers
-- E.g. typescript with a yarn install puts .config/yarn paths for libraries
dropPrefixPaths :: FilePath -> IO [Text]
dropPrefixPaths repoDir = do
  home <- Text.pack <$> getHomeDirectory
  return $ map ("file://" <>)
  -- typescript system paths
    [ home <> "/.config/yarn/global/node_modules"
    , "/usr/local/share/.config/yarn/global/node_modules"
    -- tests/CI install path
    , home <> "/.hsthrift/lib/node_modules"
   -- typescript with npm
    , "/usr/lib/node_modules"
   -- rust system paths
    , "/usr/lib"
    , home <> "/.cargo/registry"
    , home <> "/.rustup/toolchains/stable-x86_64-unknown-linux-gnu"
    , home <> "/.rustup/toolchains/stable-aarch64-unknown-linux-gnu"
    -- repoDir root, so everything is repo-relative
    , Text.pack (dropTrailingPathSeparator repoDir)
    ]

toLsifAngle :: FilePath -> Lazy.ByteString -> IO Aeson.Value
toLsifAngle repoDir str = do
  paths <- dropPrefixPaths repoDir
  (facts, env) <- parseChunks paths str
  logInfo "Generating cross-references"
  let !xrefs = evalState LSIF.emitFileFactSets  env
  let result = LSIF.generateJSON (LSIF.insertPredicateMap facts xrefs)
  return (Aeson.Array $ V.fromList result)

-- | Lazily parse lsif as one object per line. File is consumed and can be
-- dropped at end of parsing We go to some lengths to avoid retaining things,
-- just the state needed to emit xrefs at the end of
-- the analysis.
parseChunks :: [Text] -> Lazy.ByteString -> IO (LSIF.PredicateMap, LSIF.Env)
parseChunks paths str =
  let contents = map (Strict.concat . Lazy.toChunks) (Lazy.lines str)
      initState = LSIF.emptyEnv { LSIF.root = paths }
  in runStateT (runToAngle contents) initState

-- strict left fold over each chunk, producing accumulating output facts
-- and final global state of the analysis
runToAngle :: [Strict.ByteString] -> StateT LSIF.Env IO LSIF.PredicateMap
runToAngle = go HashMap.empty -- a foldlM'
  where
    go !acc [] = return acc
    go !acc (line:lines) = do
      preds <- parseAsJSON line
      go (LSIF.insertPredicateMap acc preds) lines

parseAsJSON :: Strict.ByteString -> StateT LSIF.Env IO [LSIF.Predicate]
parseAsJSON line = do
  rawjson <- liftIO $ Foreign.CPP.Dynamic.parseJSON line
  case rawjson of
    Left bad -> liftIO $ throwIO (ErrorCall (Text.unpack bad))
    Right good -> case Aeson.fromJSON good of
      Aeson.Error err -> liftIO $ throwIO (ErrorCall err)
      Aeson.Success fact -> LSIF.factToAngle fact
