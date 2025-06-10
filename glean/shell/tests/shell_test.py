# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

from __future__ import absolute_import, division, print_function, unicode_literals

import json
import os

import re
import sys

import pexpect
from libfb.py.testutil import BaseFacebookTestCase

GLEAN_PATH = os.getenv("GLEAN")
MKTESTDB_PATH = os.getenv("MAKE_TEST_DB")
SCHEMA_PATH = os.getenv("SCHEMA_SOURCE")
EXAMPLE_SCHEMA_PATH = os.getenv("EXAMPLE") + "/schema"
EXAMPLE_FACTS_PATH = os.getenv("EXAMPLE") + "/facts.glean"

REPO = "dbtest-repo"
DB = REPO + "/f00baa"
PROMPT = REPO + ">"


class GleanShellTest(BaseFacebookTestCase):
    tmpdir = None
    process = None

    @classmethod
    def startShell(cls, db, schema=SCHEMA_PATH, config=None):
        cls.tmpdir = pexpect.run("mktemp -d", encoding="utf8").strip()

        pexpect.run("mkdir " + cls.tmpdir + "/db")
        pexpect.run("mkdir " + cls.tmpdir + "/schema")
        pexpect.run(MKTESTDB_PATH + " " + cls.tmpdir + "/db")
        pexpect.run("ls " + cls.tmpdir + "/db")

        if db is None:
            db_args = []
        else:
            db_args = ["--db=" + db if db != "" else ""]

        if schema is None:
            schema_args = ["--schema=" + cls.tmpdir + "/schema"]
        else:
            schema_args = ["--schema=" + schema]

        if config is None:
            config_args = []
        else:
            with open(cls.tmpdir + "/config", "a") as f:
                f.write(config)
            config_args = ["--server-config=file:" + cls.tmpdir + "/config"]

        cls.process = pexpect.spawn(
            GLEAN_PATH,
            logfile=sys.stdout,
            encoding="utf8",
            args=["--db-root=" + cls.tmpdir + "/db"]
            + schema_args
            + config_args
            + ["shell"]
            + db_args,
        )

        if db is None:
            cls.process.expect(">")
        else:
            cls.shellCommand(":database " + db)
            cls.process.expect(PROMPT)

    @classmethod
    def setUp(cls):
        cls.startShell(DB)

    @classmethod
    def tearDown(cls):
        if cls.process:
            cls.process.sendline(":quit")
            cls.process.expect(pexpect.EOF)

    @classmethod
    def __del__(cls):
        if cls.tmpdir:
            pexpect.run("rm -rf " + cls.tmpdir)

    @classmethod
    def shellCommand(cls, cmd, prompt=PROMPT):
        cls.process.sendline(cmd)
        cls.process.expect(prompt)
        return cls.process.before


class GleanShellReload(GleanShellTest):
    @classmethod
    def setUp(cls):
        cls.startShell(None, None)

    def test(self):
        pexpect.run(
            "cp " + EXAMPLE_SCHEMA_PATH + "/example.angle " + self.tmpdir + "/schema"
        )
        self.shellCommand(":reload", ">")
        self.shellCommand(":load " + EXAMPLE_FACTS_PATH, "facts>")

        # add a new derived predicate to the schema
        with open(self.tmpdir + "/schema/example.angle", "a") as f:
            f.write(
                "schema example.2 : example.1 {"
                + "  predicate Foo:string S where Class {S,_ }"
                + "}"
                + "schema all.2 : example.2 {}"
            )
        self.shellCommand(":reload", "facts>")

        # check that we can query for the new derived predicate
        output = self.shellCommand("example.Foo.2 _", "facts>")
        self.assertIn("Fish", output)


class GleanShellSchema(GleanShellTest):
    @classmethod
    def setUp(cls):
        cls.startShell(None, schema=None)

    def test(self):
        pexpect.run(
            "cp " + EXAMPLE_SCHEMA_PATH + "/example.angle " + self.tmpdir + "/schema"
        )
        self.shellCommand(":reload", ">")
        self.shellCommand(":load " + EXAMPLE_FACTS_PATH, "facts>")

        # Now let's modify the schema, add a column field to example.Class
        pexpect.run(
            "sed -i 's/line : nat,$/line : nat, column : nat,/' "
            + self.tmpdir
            + "/schema/example.angle"
        )
        self.shellCommand(":reload", "facts>")

        # Check that we can query using the new schema, the results should
        # contain the new field column with the default value 0
        output = self.shellCommand("example.Class _", "facts>")
        self.assertIn("column", output)

        # Explicitly requesting the stored schema gives us the old facts again,
        # without the new field
        self.shellCommand(":use-schema stored", "facts>")
        output = self.shellCommand("example.Class _", "facts>")
        self.assertNotIn("column", output)
        output = self.shellCommand(":schema example.Class", "facts>")
        self.assertNotIn("column", output)

        # Explicitly requesting the current schema gives us the new facts again
        self.shellCommand(":use-schema current", "facts>")
        output = self.shellCommand("example.Class _", "facts>")
        self.assertIn("column", output)
        output = self.shellCommand(":schema example.Class", "facts>")
        self.assertIn("column", output)


class GleanShellNoDB(GleanShellTest):
    @classmethod
    def setUp(cls):
        cls.startShell(None)

    def test(self):
        output = self.shellCommand(":database " + DB)
        self.assertIn(DB, output)


class GleanShellListDBs(GleanShellTest):
    def test(self):
        output = self.shellCommand(":list")
        self.assertIn(DB, output)

        # With filter argument
        output = self.shellCommand(":list dbtest-repo")
        self.assertIn(DB, output)

        # With full DB argument
        output = self.shellCommand(":list " + DB)
        self.assertIn(DB, output)

        # With non-existent repo filter argument
        output = self.shellCommand(":list fakerepo")
        self.assertNotIn(DB, output)


class GleanShellStatistics(GleanShellTest):
    def test(self):
        output = self.shellCommand(":statistics")
        self.assertIsNotNone(re.search("glean.test.Predicate.6\r\n *count: 4", output))
        self.assertIsNotNone(re.search("sys.Blob.1\r\n *count: 2", output))
        self.assertIsNotNone(
            re.search("Total: \\d+ facts \\(\\d+\\.\\d+ kiB\\)", output)
        )


class GleanShellPredicates(GleanShellTest):
    def test(self):
        output = self.shellCommand(":schema")
        self.assertIsNotNone(re.search("glean.test.Predicate", output))


class GleanShellLoad(GleanShellTest):
    def test(self):
        repo = "test"
        prompt = repo + ">"
        self.shellCommand(
            ":load " + repo + "/0 glean/shell/tests/expr.glean", prompt=prompt
        )
        output = self.shellCommand(":db", prompt=prompt)
        self.assertIn("test/0", output)

        output = self.shellCommand(":stat", prompt=prompt)
        self.assertIsNotNone(re.search("glean.test.Expr.6\r\n *count: 6", output))

        output = self.shellCommand(
            'glean.test.Expr { lam = { var_ = "x" } }', prompt=prompt
        )
        self.assertIn("1 results", output)

        # :load <file> should choose the repo name automatically:
        self.shellCommand(":load glean/shell/tests/expr.glean", prompt="expr>")
        output = self.shellCommand(":db", prompt="expr>")
        self.assertIn("expr/0", output)

        # :load <file> again should choose a new unique repo name:
        self.shellCommand(":load glean/shell/tests/expr.glean", prompt="expr>")
        output = self.shellCommand(":db", prompt="expr>")
        self.assertIn("expr/1", output)

        # :load <db>/<hash> <file> where any file fails to load, and the DB does
        # not exist should, not create the DB
        output = self.shellCommand(
            ":load test/2 glean/shell/tests/expr.glean foo.json", prompt="expr>"
        )
        self.assertIn("Exception: foo.json", output)
        output = self.shellCommand(":db test/2", prompt="expr>")
        self.assertIn("Exception: UnknownDatabase", output)

        # :load <db>/<hash> <file> where all files can be parsed but the DB
        # already exists, should fail the operation
        output = self.shellCommand(
            ":load test/0 glean/shell/tests/expr.glean", prompt="expr>"
        )
        self.assertIn("Exception: database already exists", output)


class GleanShellCreate(GleanShellTest):
    def test(self):
        prompt = "tmp>"
        self.shellCommand(":create", prompt=prompt)
        output = self.shellCommand(":db", prompt=prompt)
        self.assertIn("tmp", output)

        output = self.shellCommand(":stat", prompt=prompt)
        self.assertIsNotNone(re.search("0 facts", output))

        prompt = "test>"
        self.shellCommand(":create test/0", prompt=prompt)
        output = self.shellCommand(":db", prompt=prompt)
        self.assertIn("test/0", output)

        output = self.shellCommand(":stat", prompt=prompt)
        self.assertIsNotNone(re.search("0 facts", output))


class GleanShellLoadIncomplete(GleanShellTest):
    def test(self):
        self.shellCommand(":load glean/shell/tests/error.glean")
        output = self.shellCommand(":list error/0")
        # Check that the DB didn't complete
        self.assertIn("(incomplete)", output)


class GleanShellOwner(GleanShellTest):
    def test(self):
        repo = "owner"
        prompt = repo + ">"

        # facts in owner.glean replicate the test setup from IncrementalTest.hs
        self.shellCommand(
            ":load " + repo + "/0 glean/shell/tests/owner.glean", prompt=prompt
        )
        output = self.shellCommand(":db", prompt=prompt)
        self.assertIn("owner/0", output)

        # 1024 should be the first fact created, i.e. Node "d"
        output = self.shellCommand(":!owner 1024", prompt="owner>")
        self.assertIn("B || C || D", output)


class GleanShellDump(GleanShellTest):
    def test(self):
        dumpfile = self.tmpdir + "/test.glean"
        self.shellCommand(":dump " + dumpfile)
        repo = "test"
        prompt = repo + ">"
        self.shellCommand(":load " + repo + "/0 " + dumpfile, prompt=prompt)
        output = self.shellCommand(":stat", prompt=prompt)
        self.assertIsNotNone(re.search("sys.Blob.1\r\n *count: 2", output))


class GleanShellCompletion(GleanShellTest):
    def test(self):
        # test completing the argument of :schema
        output = self.shellCommand(":schema glean.test.Ex\t")
        self.assertIsNotNone(re.search("predicate glean.test.Expr.6 :", output))
        # test completing a predicate name in a query
        output = self.shellCommand('glea\tP\t { string_ = "acca" }')
        # test that we completed to the correct thing
        self.assertIn("1 results", output)


class GleanShellAngle(GleanShellTest):
    def test(self):
        self.shellCommand(":mode angle")

        # A query with no pattern - match all the facts.
        output = self.shellCommand("sys.Blob _")
        self.assertIn('"hello"', output)
        self.assertIn('"bye"', output)

        # A query with a pattern
        output = self.shellCommand(
            "glean.test.Predicate.6 { named_sum_ = { tue = 37 }}"
        )
        self.assertIn("1 results", output)
        self.assertIn('"byt": 33', output)

        # Match and recursively expand
        output = self.shellCommand(
            'B = sys.Blob "bye"; glean.test.Predicate { pred = B }'
        )
        self.assertIn("2 results", output)

        # Recursively expand a fact by Id
        self.shellCommand(":limit 1")
        output = self.shellCommand("cxx1.FunctionName _")
        fact1 = output[output.find("{ ") : output.rfind("}") + 1]
        j = json.loads(fact1)
        output = self.shellCommand("{" + str(j["id"]) + "}")
        self.assertIn("2 facts", output)
        fact2 = output[output.find("{ ") : output.rfind("}") + 1]
        self.assertEqual(fact1, fact2)

        # Test querying for things that aren't full facts
        output = self.shellCommand('prim.toLower "AbC"')
        self.assertIn("abc", output)

        output = self.shellCommand("prim.length [0, 0, 0, 0]")
        self.assertIn('"key": 4', output)

        output = self.shellCommand('prim.length ["Hello", "World"]')
        self.assertIn('"key": 2', output)


class GleanShellQueryProfiling(GleanShellTest):
    def test(self):
        self.shellCommand(":profile full")

        output = self.shellCommand(
            'glean.test.Predicate { pred = "hello" } | '
            + "glean.test.Predicate { nat = 42 }"
        )
        self.assertIn("glean.test.Predicate.6 : 8", output)
        self.assertIn("sys.Blob.1 : 1", output)


class GleanShellQueryDebug(GleanShellTest):
    def test(self):
        self.shellCommand(":debug all")

        output = self.shellCommand("3")
        self.assertIn("ir:", output)
        self.assertIn("bytecode:", output)


class GleanShellExpand(GleanShellTest):
    def test(self):
        self.shellCommand(":expand off")
        output = self.shellCommand('glean.test.Tree { node = { label = "a".. }}')
        self.assertNotIn('{ "label": "d" }', output)

        self.shellCommand(":expand on")
        output = self.shellCommand('glean.test.Tree { node = { label = "a" }}')
        self.assertIn('{ "label": "d" }', output)

        self.shellCommand(":expand glean.test.Node")
        output = self.shellCommand('glean.test.Tree { node = { label = "a".. }}')
        self.assertIn('{ "label": "a" }', output)
        self.assertNotIn('{ "label": "d" }', output)

        self.shellCommand(":expand glean.test.Tree")
        output = self.shellCommand('glean.test.Tree { node = { label = "a" }}')
        self.assertNotIn('{ "label": "d" }', output)
