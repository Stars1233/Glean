/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

include "glean/config/server/server_config.thrift"
include "glean/if/glean.thrift"

namespace cpp2 facebook.glean.thrift.internal
namespace hs Glean

// The Schema stored in a DB
struct StoredSchema {
  1: string_321 schema;
  2: map<glean.Id, glean.PredicateRef> predicateIds;

  // We store the SchemaId corresponding to each all.version in the
  // DB's schema. This is so that if the internal fingerprinting of
  // schemas (Glean.Database.Schema.ComputeIds) changes for whatever
  // reason, the SchemaIds that were previously computed remain
  // unchanged. Internal PredicateId and TypeId hashes might change,
  // but those aren't exposed externally.
  //
  // Note: as with SchemaInstance below, this is a map for legacy reasons
  // and MUST HAVE A SINGLE ENTRY.
  3: map<string, glean.Version> versions;
}

// -----------------------------------------------------------------------------
// DB metadata

struct DatabaseIncomplete {}

struct DatabaseFinalizing {}

// The status of data being written into a DB
union Completeness {
  1: DatabaseIncomplete incomplete;
  3: glean.DatabaseComplete complete;
  4: glean.DatabaseBroken broken;
  5: DatabaseFinalizing finalizing;
} (hs.prefix = "", hs.nonempty)

// Information about a database stored by Glean.
struct Meta {
  // Database version
  1: server_config.DBVersion metaVersion;

  // When was the database created
  2: glean.PosixEpochTime metaCreated;

  // Completeness status
  3: Completeness metaCompleteness;

  // Backup status
  4: optional string metaBackup;

  // Arbitrary metadata about this DB. Properties prefixed by
  // "glean."  are reserved for use by Glean itself.
  5: glean.DatabaseProperties metaProperties;

  // What this DB depends on.
  6: optional glean.Dependencies metaDependencies;

  // Whether all facts for a predicate have already been inserted.
  7: list<glean.PredicateRef> metaCompletePredicates;

  // Temporary: indicates that all non-derived predicates are complete.
  // Later we will allow non-derived predicates to be completed separately
  // and store that information in metaCompletePredicates.
  8: bool metaAxiomComplete;

  // If present, this is the time when the source data was read.
  // This should always be earlier than created time.
  9: optional glean.PosixEpochTime metaRepoHashTime;
} (hs.prefix = "")

// ---------------------------------------------------------------------------
// Schema index

struct SchemaInstance {
  // The SchemaId and the all.N version to use.
  //
  // For legacy reasons this is a map, but it MUST HAVE EXACTLY ONE ENTRY.
  //
  // The schema source may contain multiple all.N schemas; the version
  // here specifies which all.N is used to construct the scope for
  // clients using this schema ID. e.g. if the schema source contains
  //
  //    schema all.1 : cxx.1
  //    schema all.2 : cxx.2
  //
  // the schema index may look like
  //
  //     {
  //       "current" : {
  //         "versions": { "1234" : "2" }
  //         "file" : "instances/1234"
  //       },
  //       "older" : [
  //         {
  //           "versions": { "5678" : "1" }
  //           "file" : "instances/5678"
  //         },
  //       ..
  //       ]
  //    }
  //
  // i.e. there is one entry in the index for each all.N version, and
  // each one has a complete copy of the schema source.
  //
  // We could recompute the schema ID from the schema, but storing it
  // in the index is better:
  //  - we can change the hashing strategy and the server will still work
  //    with the existing schemas. This is actually a critical property,
  //    because the hashing strategy often changes e.g. when we modify
  //    the Angle AST type.
  //  - if we want to deploy a fix to a schema without changing its hash,
  //    we can do that
  //
  // The keys are morally SchemaId, but when I used SchemaId as the key
  // there were spurious quotes surrounding the string produced by the
  // JSON serializer - not sure if this was a bug in the Haskell JSON Thrift
  // serializer or if it's the "correct" behaviour.
  1: map<string, glean.Version> versions;

  // Points to the file containing the schema source
  3: string file;
}

struct SchemaIndex {
  // The current schema
  1: SchemaInstance current;

  // Older versions of the schema we also know about
  2: list<SchemaInstance> older;
}

// The following were automatically generated and may benefit from renaming.
typedef string (hs.type = "ByteString") string_321
