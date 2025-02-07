{-
  Copyright (c) Meta Platforms, Inc. and affiliates.
  All rights reserved.

  This source code is licensed under the BSD-style license found in the
  LICENSE file in the root directory of this source tree.
-}

module Glean.Regression.Config
  ( TestConfig(..)
  ) where

import Glean.Types

-- | Test configuration
data TestConfig = TestConfig
  { testRepo :: Repo
  , testOutput :: FilePath
      -- ^ directory in which to store *all* output and temporary files
  , testRoot :: FilePath
      -- ^ directory with source files to index
  , testProjectRoot :: FilePath
      -- ^ top-level directory (fbsource/fbcode)
  , testGroup :: String
      -- ^ test group. Groups are used to run the whole set of tests
      -- multiple ways, e.g. for different platforms.
  , testSchema :: Maybe FilePath
      -- ^ Directory containing the schema files
  } deriving (Show)
