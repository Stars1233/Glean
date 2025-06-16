{-
  Copyright (c) Meta Platforms, Inc. and affiliates.
  All rights reserved.

  This source code is licensed under the BSD-style license found in the
  LICENSE file in the root directory of this source tree.
-}

module Glean.Glass.Search
  ( searchEntity
  , searchEntityLocation
  , SearchResult(..)
  , SearchEntity(..)
  , CodeEntityLocation(..)
  ) where

import Data.Text ( Text )

import Glean.Glass.Repos (Language(..) )
import Glean.Glass.SymbolId ( toShortCode )

import Glean.Glass.Search.Class as Search
    ( Search(symbolSearch),
      SearchResult(..),
      SearchEntity(..),
      CodeEntityLocation(..),
      ResultLocation,
      mapResultLocation)
import qualified Glean.Glass.Search.Angle ({- instances -})
import qualified Glean.Glass.Search.Buck ({- instances -})
import qualified Glean.Glass.Search.Cxx ({- instances -})
import qualified Glean.Glass.Search.Erlang ({- instances -})
import qualified Glean.Glass.Search.Flow ({- instances -})
import qualified Glean.Glass.Search.GraphQL ({- instances -})
import qualified Glean.Glass.Search.Hack ({- instances -})
import qualified Glean.Glass.Search.Haskell ({- instances -})
import qualified Glean.Glass.Search.LSIF ({- instances -})
import qualified Glean.Glass.Search.Pp ({- instances -})
import qualified Glean.Glass.Search.Python ({- instances -})
import qualified Glean.Glass.Search.SCIP ({- instances -})
import qualified Glean.Glass.Search.Thrift ({- instances -})
import qualified Glean.Schema.Code.Types as Code
import qualified Glean.Haxl.Repos as Glean
import Glean.Glass.Utils ( fst4 )

--
-- | Entity search: decodes a symbol id to a code.Entity fact
--
-- Note: this is different to e.g. approximate string search, as we
-- should _always_ be able to decode valid symbol ids back to their (unique*)
-- entity. Unlike searchSymbol() we typically have full entity scope information
-- sufficient to uniquely identify the symbol in an index.
--
-- There are cases where symbol ids are not unique:
--
-- - weird code
-- - hack namespaces
-- - bugs/approximations in our encoder
--
-- We log the duplicates to glass_errors
--
searchEntityLocation
  :: Language
  -> [Text]
  -> Glean.ReposHaxl u w (SearchResult (ResultLocation Code.Entity))
searchEntityLocation lang toks = case lang of
  Language_Angle ->
    fmap (mapResultLocation Code.Entity_angle) <$> Search.symbolSearch toks
  Language_Buck ->
    fmap (mapResultLocation Code.Entity_buck) <$> Search.symbolSearch toks
  Language_Cpp ->
    fmap (mapResultLocation Code.Entity_cxx) <$> Search.symbolSearch toks
  Language_Erlang ->
    fmap (mapResultLocation Code.Entity_erlang) <$> Search.symbolSearch toks
  Language_GraphQL ->
    fmap (mapResultLocation Code.Entity_graphql) <$> Search.symbolSearch toks
  Language_Hack ->
    fmap (mapResultLocation Code.Entity_hack) <$> Search.symbolSearch toks
  Language_Haskell ->
    fmap (mapResultLocation Code.Entity_hs) <$> Search.symbolSearch toks
  Language_JavaScript ->
    fmap (mapResultLocation Code.Entity_flow) <$> Search.symbolSearch toks
  Language_PreProcessor ->
    fmap (mapResultLocation Code.Entity_pp) <$> Search.symbolSearch toks
  Language_Python ->
    fmap (mapResultLocation Code.Entity_python) <$> Search.symbolSearch toks
  Language_Thrift ->
    fmap (mapResultLocation Code.Entity_fbthrift) <$> Search.symbolSearch toks
  -- scip-based indexers
  Language_Rust ->
    fmap (mapResultLocation Code.Entity_scip) <$> Search.symbolSearch toks
  Language_Go ->
    fmap (mapResultLocation Code.Entity_scip) <$> Search.symbolSearch toks
  Language_TypeScript ->
    fmap (mapResultLocation Code.Entity_scip) <$> Search.symbolSearch toks
  Language_Java ->
    fmap (mapResultLocation Code.Entity_scip) <$> Search.symbolSearch toks
  Language_Kotlin ->
    fmap (mapResultLocation Code.Entity_scip) <$> Search.symbolSearch toks
  lang ->
    return $ None $ "searchEntity: language not supported: " <> toShortCode lang

searchEntity
  :: Language
  -> [Text]
  -> Glean.ReposHaxl u w (SearchResult Code.Entity)
searchEntity lang toks = case lang of
  Language_Thrift -> fmap Code.Entity_fbthrift <$> Search.symbolSearch toks
  _ -> fmap fst4 <$> searchEntityLocation lang toks
