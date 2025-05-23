{-
  Copyright (c) Meta Platforms, Inc. and affiliates.
  All rights reserved.

  This source code is licensed under the BSD-style license found in the
  LICENSE file in the root directory of this source tree.
-}

{-# LANGUAGE TypeApplications #-}
module Glean.Backend.Types
  (
    -- * Types
    Backend(..)
  , StackedDbOpts(..)
  , LogDerivationResult

    -- * Operations
  , SchemaPredicates
  , loadPredicates
  , loadPredicatesForSchema
  , databases
  , localDatabases
  , create
  , finish
  , fillDatabase
  , finalize
  , completePredicates
  , untilDone

    -- * Haxl
  , GleanGet(..)
  , GleanQuery(..)
  , GleanFetcher
  , GleanQueryer
  , Haxl.State(..)
  , QueryResult(..)
  , AppendList(..)
  , fromAppendList

    -- * Shards
  , dbShard
  , dbShardWord
  ) where

import qualified Data.ByteString.Unsafe as B
import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Bits
import Data.Default
import Data.Hashable
import qualified Data.HashMap.Strict as HashMap
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word
import Data.Typeable
import Foreign.Ptr
import GHC.Fingerprint
import qualified Haxl.Core as Haxl
import System.IO.Unsafe

import Util.Control.Exception
import Util.Time (DiffTimePoints)

import Glean.Query.Thrift.Internal
import Glean.Typed
import qualified Glean.Types as Thrift
import Glean.Util.Some
import Glean.Util.ThriftService (DbShard)
import Glean.Types
import Data.Either

data StackedDbOpts
  = IncludeBase
  | ExcludeBase
  deriving (Eq, Show)

-- |
-- An abstraction over Glean's Thrift API. This allows client code
-- to work with either a local or remote backend, chosen at runtime.
--
class Backend a where
  queryFact :: a -> Thrift.Repo -> Thrift.Id -> IO (Maybe Thrift.Fact)
  factIdRange :: a -> Thrift.Repo -> IO Thrift.FactIdRange
  getSchemaInfo :: a -> Maybe Thrift.Repo -> Thrift.GetSchemaInfo
    -> IO Thrift.SchemaInfo
  validateSchema :: a -> Thrift.ValidateSchema -> IO ()
  predicateStats :: a -> Thrift.Repo -> StackedDbOpts
    -> IO (Map Thrift.Id Thrift.PredicateStats)
  listDatabases :: a -> Thrift.ListDatabases -> IO Thrift.ListDatabasesResult
  getDatabase :: a -> Thrift.Repo -> IO Thrift.GetDatabaseResult

  userQueryFacts :: a -> Thrift.Repo -> Thrift.UserQueryFacts
    -> IO Thrift.UserQueryResults
  userQuery :: a -> Thrift.Repo -> Thrift.UserQuery
    -> IO Thrift.UserQueryResults
  userQueryBatch :: a -> Thrift.Repo -> Thrift.UserQueryBatch
    -> IO [Thrift.UserQueryResultsOrException]

  deriveStored :: a -> LogDerivationResult -> Thrift.Repo
    -> Thrift.DerivePredicateQuery -> IO Thrift.DerivationStatus

  kickOffDatabase :: a -> Thrift.KickOff -> IO Thrift.KickOffResponse
  finishDatabase :: a -> Thrift.Repo -> IO Thrift.FinishDatabaseResponse
  finalizeDatabase :: a -> Thrift.Repo -> IO Thrift.FinalizeResponse

  updateProperties
    :: a
    -> Thrift.Repo
    -> Thrift.DatabaseProperties
    -> [Text]
    -> IO Thrift.UpdatePropertiesResponse

  completePredicates_
    :: a
    -> Thrift.Repo
    -> Thrift.CompletePredicates
    -> IO Thrift.CompletePredicatesResponse

  -- | Request a backed up database (specified via its backup locator) to be
  -- made available. This call doesn't wait until the database actually becomes
  -- available, it only issues the request.
  --
  -- This might (for local databases) or might not (for databases on a Thrift
  -- server) return an STM action that waits for the restore operation.
  restoreDatabase :: a -> Text -> IO ()

  -- For a local database this will delete the specified repo
  deleteDatabase :: a -> Thrift.Repo -> IO Thrift.DeleteDatabaseResult

  -- Enqueue a batch for writing
  enqueueBatch :: a -> Thrift.ComputedBatch -> IO Thrift.SendResponse

  -- Enqueue a JSON batch for writing
  enqueueJsonBatch
    :: a
    -> Thrift.Repo
    -> Thrift.SendJsonBatch
    -> IO Thrift.SendJsonBatchResponse

  -- Enqueue a batch descriptor to be downloaded and written
  enqueueBatchDescriptor
    :: a
    -> Thrift.Repo
    -> Thrift.EnqueueBatch
    -> Thrift.EnqueueBatchWaitPolicy
    -> IO Thrift.EnqueueBatchResponse

  -- Poll the status of a write batch
  pollBatch :: a -> Thrift.Handle -> IO Thrift.FinishResponse

  -- | Render for debugging
  displayBackend :: a -> String

  -- | For a given 'Repo', check whether any servers have the DB.  If
  -- the backend is remote and using shards, this should check whether
  -- any servers are advertising the appropriate shard.
  hasDatabase :: a -> Thrift.Repo -> IO Bool

  -- | The schema version the client wants to use. This is sent along
  -- with queries.
  schemaId :: a -> Maybe Thrift.SchemaId

  -- | True if this is a distributed backend, and different servers
  -- may have different DBs. If this returns True, then `hasDatabase`
  -- can be used to check the availability of a DB.
  usingShards :: a -> Bool

  -- | Initialise the Haxl state for this Backend.
  initGlobalState :: a -> IO (Haxl.State GleanGet, Haxl.State GleanQuery)


-- | The exception includes the length of time from start to error
type LogDerivationResult =
  Either (DiffTimePoints, SomeException) Thrift.UserQueryStats -> IO ()

instance Backend (Some Backend) where
  queryFact (Some backend) = queryFact backend
  factIdRange (Some backend) = factIdRange backend
  getSchemaInfo (Some backend) = getSchemaInfo backend
  validateSchema (Some backend) = validateSchema backend
  predicateStats (Some backend) = predicateStats backend
  listDatabases (Some backend) = listDatabases backend
  getDatabase (Some backend) = getDatabase backend
  userQueryFacts (Some backend) = userQueryFacts backend
  userQuery (Some backend) = userQuery backend
  userQueryBatch (Some backend) = userQueryBatch backend
  deriveStored (Some backend) = deriveStored backend

  kickOffDatabase (Some backend) = kickOffDatabase backend
  finishDatabase (Some backend) = finishDatabase backend
  finalizeDatabase (Some backend) = finalizeDatabase backend
  updateProperties (Some backend) = updateProperties backend
  completePredicates_ (Some backend) = completePredicates_ backend

  restoreDatabase (Some backend) = restoreDatabase backend
  deleteDatabase (Some backend) = deleteDatabase backend

  enqueueBatch (Some backend) = enqueueBatch backend
  enqueueJsonBatch (Some backend) = enqueueJsonBatch backend
  enqueueBatchDescriptor (Some backend) = enqueueBatchDescriptor backend
  pollBatch (Some backend) = pollBatch backend
  displayBackend (Some backend) = displayBackend backend
  hasDatabase (Some backend) = hasDatabase backend
  schemaId (Some backend) = schemaId backend
  usingShards (Some backend) = usingShards backend
  initGlobalState (Some backend) = initGlobalState backend

-- -----------------------------------------------------------------------------
-- Functionality built on Backend

loadPredicates
  :: Backend a
  => a
  -> Thrift.Repo
  -> [SchemaPredicates]
  -> IO Predicates
loadPredicates backend repo refs =
  makePredicates refs <$> getSchemaInfo backend (Just repo)
    def { Thrift.getSchemaInfo_omit_source = True }

loadPredicatesForSchema :: Backend a => a -> SchemaId -> IO Predicates
loadPredicatesForSchema backend schemaId = do
  info <- getSchemaInfo backend Nothing
    def {
      Thrift.getSchemaInfo_select = Thrift.SelectSchema_schema_id schemaId,
      Thrift.getSchemaInfo_omit_source = True
    }
  return $ makePredicates [Map.elems (Thrift.schemaInfo_predicateIds info)] info

databases :: Backend a => a -> IO [Thrift.Database]
databases be =
  Thrift.listDatabasesResult_databases <$>
    listDatabases be def { Thrift.listDatabases_includeBackups = True }

localDatabases :: Backend a => a -> IO [Thrift.Database]
localDatabases be =
  Thrift.listDatabasesResult_databases <$>
    listDatabases be def { Thrift.listDatabases_includeBackups = False }

-- | Create a database and run the supplied IO action to write data
-- into it. When the IO action returns, the DB will be marked complete
-- and cannot be modified further.
fillDatabase
  :: Backend a
  => a
    -- ^ The backend
  -> Repo
    -- ^ The repo to create
  -> Maybe Dependencies
    -- ^ Optionally stack the new DB on another DB
  -> IO ()
    -- ^ What to do if the DB already exists. @return ()@ to continue,
    -- or @throwIO@ to forbid.
  -> IO b
    -- ^ Caller-supplied action to write data into the DB.
  -> IO b
fillDatabase env repo maybeDeps ifexists action =
  tryBracket
    (do
      exists <- create env repo maybeDeps
      when exists ifexists
    )
    (\_ ex -> do
      when (isRight ex) $ do
        finish env repo
    )
    (const action)

-- | Create a database. The schema ID is set from the Backend.
create
  :: Backend a
  => a
  -> Repo
  -> Maybe Dependencies
  -> IO Bool  -- ^ Returns 'True' if the DB already existed
create backend repo maybeDeps = do
  r <- kickOffDatabase backend def
    { kickOff_repo = repo
    , kickOff_properties = HashMap.fromList $
        [ ("glean.schema_id", id)
        | Just (SchemaId id) <- [schemaId backend]
        ]
    , kickOff_dependencies = maybeDeps
    }
  return (kickOffResponse_alreadyExists r)

-- | Finish a DB created with 'create'
finish
  :: Backend a
  => a
  -> Repo
  -> IO ()
finish backend repo = do
  void $ finishDatabase backend repo
  finalize backend repo

-- | Wait for a database to finish finalizing and enter the "complete"
-- state after all writing has finished. Before the database is
-- complete, it may be queried but a stacked database cannot be
-- created on top of it.
finalize :: Backend a => a -> Repo -> IO ()
finalize env repo =
  void $ untilDone $ finalizeDatabase env repo

-- | Notify the server when non-derived predicates are complete. This
-- must be called before derivedStored.
completePredicates :: Backend a => a -> Repo -> CompletePredicates -> IO ()
completePredicates env repo preds =
  void $ untilDone $ completePredicates_ env repo preds

untilDone :: IO a -> IO a
untilDone io = loop
  where
  loop = do
    r <- try io
    case r of
      Right a -> return a
      Left (Retry n) -> do
        threadDelay (truncate (n * 1000000))
        loop


-- -----------------------------------------------------------------------------
-- Haxl

data GleanGet p where
  Get
    :: (Typeable p, Show p, Predicate p)
    => {-# UNPACK #-} !(IdOf p)
    -> Bool
    -> Repo
    -> GleanGet p
  GetKey
    :: (Typeable p, Show p, Predicate p)
    => {-# UNPACK #-} !(IdOf p)
    -> Bool
    -> Repo
    -> GleanGet (KeyType p)

deriving instance Show (GleanGet a)
instance Haxl.ShowP GleanGet where showp = show

instance Eq (GleanGet p) where
  (Get p rec repo) == (Get q rec' repo') =
    p == q && rec == rec' && repo == repo'
  (GetKey (p :: IdOf a) rec repo) == (GetKey (q :: IdOf b) rec' repo')
    | Just Refl <- eqT @a @b = p == q && rec == rec' && repo == repo'
    -- the KeyTypes being equal doesn't tell us that the predicates are
    -- equal, so we need to check that with eqT here.
  _ == _ = False

instance Hashable (GleanGet a) where
  hashWithSalt salt (Get p rec repo) =
    hashWithSalt salt (0::Int, typeOf p, p, rec, repo)
  hashWithSalt salt (GetKey p rec repo) =
    hashWithSalt salt (1::Int, typeOf p, p, rec, repo)

instance Haxl.DataSourceName GleanGet where
  dataSourceName _ = "GleanGet"

type GleanFetcher = Haxl.PerformFetch GleanGet

instance Haxl.StateKey GleanGet where
  data State GleanGet = GleanGetState GleanFetcher

instance Haxl.DataSource u GleanGet where
  fetch (GleanGetState fetcher) _ _ = fetcher

{-
Why is streaming handled behind the datasource abstraction instead of
exposing resumable queries as a request?  Because exposing resumable
queries as a Haxl data fetch would mean hashing the continuation and
keeping it in the Haxl cache.
-}

data GleanQuery a where
  QueryReq
    :: (Show q, Typeable q, QueryResult q r)
    => Query q   -- The query
    -> Repo
    -> Bool -- stream all results?
    -> GleanQuery (r, Bool)

-- | List with O(1) append and O(n) conversion to [], aka DList
newtype AppendList a = AppendList ([a] -> [a])

instance Semigroup (AppendList a) where
  AppendList x <> AppendList y = AppendList (x . y)

instance Monoid (AppendList a) where
  mempty = AppendList id

fromAppendList :: AppendList a -> [a]
fromAppendList (AppendList f) = f []

instance Show a => Show (AppendList a) where
  show = show . fromAppendList

class Monoid r => QueryResult q r where
  fromResults :: [q] -> r

instance QueryResult q (AppendList q) where
  fromResults qs = AppendList (qs++)

instance QueryResult q (Sum Int) where
  fromResults = Sum . length

deriving instance Show (GleanQuery q)
instance Haxl.ShowP GleanQuery where showp = show

instance Eq (GleanQuery r) where
  QueryReq (q1 :: Query a) repo1 s1 == QueryReq (q2 :: Query b) repo2 s2
    | Just Refl <- eqT @a @b = q1 == q2 && repo1 == repo2 && s1 == s2
  _ == _ = False

instance Hashable (GleanQuery q) where
  hashWithSalt salt (QueryReq q s repo) = hashWithSalt salt (q,s,repo)


instance Haxl.DataSourceName GleanQuery where
  dataSourceName _ = "GleanQuery"

type GleanQueryer = Haxl.PerformFetch GleanQuery

instance Haxl.StateKey GleanQuery where
  data State GleanQuery = GleanQueryState GleanQueryer

instance Haxl.DataSource u GleanQuery where
  fetch (GleanQueryState queryer) _ _ = queryer

-- -----------------------------------------------------------------------------
-- Shards

dbShard :: Thrift.Repo -> DbShard
dbShard = Text.pack . show . dbShardWord

dbShardWord :: Thrift.Repo -> Word64
dbShardWord Thrift.Repo{..} =
  unsafeDupablePerformIO $ B.unsafeUseAsCStringLen repo $ \(ptr,len) -> do
      -- Use GHC's md5 binding. If this ever changes then the test in
      -- hs/tests/TestShard.hs will detect it.
    Fingerprint w _ <- fingerprintData (castPtr ptr) len
    return (w `shiftR` 1)
       -- SR doesn't like shards >= 0x8000000000000000
  where
  repo = Text.encodeUtf8 repo_name <> "/" <> Text.encodeUtf8 repo_hash
