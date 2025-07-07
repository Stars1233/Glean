{-
  Copyright (c) Meta Platforms, Inc. and affiliates.
  All rights reserved.

  This source code is licensed under the BSD-style license found in the
  LICENSE file in the root directory of this source tree.
-}

{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ConstraintKinds #-}
-- Copyright 2004-present Facebook. All Rights Reserved.

{-# OPTIONS_GHC -Wno-star-is-type -Wno-orphans #-}
module Glean.Glass.Attributes.Class
  ( ToAttributes(..)
  , LogAttr(..)
  , RefEntitySymbol
  , DefEntitySymbol
  , extendAttributes
  , attrListToMap
  , attrMapToList
  ) where

import qualified Data.Map as Map
import qualified Data.Aeson as A

import qualified Glean
import qualified Glean.Haxl.Repos as Glean
import qualified Haxl.DataSource.Glean as Glean (HasRepo)
import Glean.Glass.Types

import Glean.Glass.SourceControl ( SourceControl )
import qualified Glean.Schema.Src.Types as Src ( File )
import qualified Glean.Schema.Code.Types as Code



-- | Class for defining log structures that can be converted to JSON text
class LogAttr a where
  -- | Convert the structure to a single JSON-formatted text string
  toLogText :: a -> A.Value

instance LogAttr () where
  toLogText _ = A.Null

-- | Class for querying attributes and converting them to thrift
class LogAttr (AttrLog key) => ToAttributes key where

  type AttrRep key :: *
  type FileAttrRep key :: *
  type AttrLog key :: *

  -- | Fetch the metadata about the attributes for this file
  -- e.g. a list of available denominators/slices
  queryMetadataForFile
    :: key
    -> Maybe Int
    -> Glean.IdOf Src.File
    -> AttributeOptions
    -> Revision
    -> Glean.RepoHaxl u w [FileAttrRep key]

  fileAttrsToAttributeList
   :: key
    -> [FileAttrRep key]
    -> Maybe AttributeList

  -- | Fetch the data for this attribute type for a file
  queryForFile
    :: (SourceControl scm, Glean.HasRepo u)
    => key
    -> Maybe Int
    -> Glean.IdOf Src.File
    -> AttributeOptions
    -> scm
    -> RepoName
    -> Path
    -> Revision
    -> [FileAttrRep key]
    -> Glean.RepoHaxl u w [AttrRep key]

  -- | Add attributes to symbols
  augmentSymbols
    :: key
    -> [AttrRep key]
    -> [RefEntitySymbol]
    -> [DefEntitySymbol]
    -> AttributeOptions
    -> ([RefEntitySymbol], [DefEntitySymbol], AttrLog key)

type RefEntitySymbol = (Code.Entity, ReferenceRangeSymbolX)
type DefEntitySymbol = (Code.Entity, DefinitionSymbolX)

-- | Given some definitions, combine their attributes from any additional
-- ones in the attribute maps. Helper for implementing augmentSymbols.
extendAttributes
  :: Ord k
  => (SymbolId -> Code.Entity -> k)
  -> Map.Map k Attributes
  -> [RefEntitySymbol]
  -> [DefEntitySymbol]
  -> ([RefEntitySymbol], [DefEntitySymbol])
extendAttributes keyFn attrMap theRefs theDefs = (refs, defs)
  where
    defs = map (uncurry extendDef) theDefs
    refs = map (uncurry extendRef) theRefs

    extend symId entity def = case Map.lookup (keyFn symId entity) attrMap of
      Nothing -> def
      Just attr -> attrMapToList attr <> def

    extendRef entity ref@ReferenceRangeSymbolX{..} = (entity,) $
        ref { referenceRangeSymbolX_attributes = attrs }
      where
        attrs = extend referenceRangeSymbolX_sym entity
          referenceRangeSymbolX_attributes

    extendDef entity def@DefinitionSymbolX{..} = (entity,) $
        def { definitionSymbolX_attributes = attrs }
      where
        attrs = extend definitionSymbolX_sym entity
          definitionSymbolX_attributes

instance Prelude.Semigroup AttributeList where
  AttributeList a <> AttributeList b = AttributeList (a <> b)

-- | Convert between attribute bag representations
attrMapToList :: Attributes -> AttributeList
attrMapToList (Attributes attrMap) = AttributeList $
    map pair $ Map.toList attrMap
  where
    pair (k,v) = KeyedAttribute k v

-- | Convert attribute list to map keyed by attr key
attrListToMap :: AttributeList -> Attributes
attrListToMap (AttributeList elems) = Attributes $
    Map.fromList $ map unpair elems
  where
    unpair (KeyedAttribute k v) = (k,v)
