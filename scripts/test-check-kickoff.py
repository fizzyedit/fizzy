#!/usr/bin/env python3
"""Exercise kickoff validation and its file and issue-number interfaces."""

import importlib.machinery
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("check-kickoff")
loader = importlib.machinery.SourceFileLoader("kickoff", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
kickoff = importlib.util.module_from_spec(spec)
loader.exec_module(kickoff)


class KickoffTests(unittest.TestCase):
    def setUp(self):
        self.fields = kickoff.template_fields()
        self.values = {name: "example" for name in self.fields}
        self.values.update(Branch="ci/check-kickoff", Gates="scripts/zb build",
                           Rules="PRs say Part of fizzyedit/work#42",
                           Serves="docs/VISION.md#mobile", **{"In bounds": "core/Foo.zig"},
                           Acceptance="`core/Foo.zig` test \"foo\" fails on main")

    def body(self):
        return "\n".join(f"{name}: {value}" for name, value in self.values.items())

    def test_valid_and_form(self):
        self.assertEqual(kickoff.validate(self.body(), self.fields), [])
        form = "\n\n".join(f"### {name}\n\n{value}" for name, value in self.values.items())
        self.assertEqual(kickoff.validate(form, self.fields), [])

    def test_each_missing_or_empty_field(self):
        for name in self.fields:
            for value in (None, "", "_No response_"):
                with self.subTest(name=name, value=value):
                    saved = self.values.pop(name)
                    if value is not None:
                        self.values[name] = value
                    failures = kickoff.validate(self.body(), self.fields)
                    self.assertTrue(any(f.startswith(name + ":") for f in failures))
                    self.values[name] = saved

    def test_all_failures_reported(self):
        self.values.update(Branch="Bad branch", Gates="scripts/zb zig build", Rules="no reference",
                           Serves="docs/VISION.md#nowhere")
        failures = kickoff.validate(self.body() + "x" * kickoff.MAX_CHARACTERS, self.fields)
        self.assertEqual({f.split(":")[0] for f in failures}, {"Branch", "Gates", "Rules", "Serves", "Body"})

    def test_length_boundary_and_unicode(self):
        body = self.body() + "\né" * 10
        body += "x" * (kickoff.MAX_CHARACTERS - len(body))
        self.assertEqual(kickoff.validate(body, self.fields), [])
        self.assertTrue(any(f.startswith("Body:") for f in kickoff.validate(body + "x", self.fields)))

    def test_branch_and_multiline_rules(self):
        for branch in ("ci/a._-9", "ci/A", "ci/a/b", "ci/", "ci/a extra"):
            self.values["Branch"] = branch
            failures = kickoff.validate(self.body(), self.fields)
            self.assertEqual(bool(failures), branch != "ci/a._-9")
        self.values["Branch"] = "ci/check"
        self.values["Rules"] = '\n- PRs say "Part of fizzyedit/work#N".'
        self.assertEqual(kickoff.validate(self.body(), self.fields), [])

    def test_spec_holds_free_text(self):
        self.values["Spec"] = "\nGates: not a field here\nTask:\n" + "x" * 5000
        self.assertEqual(kickoff.validate(self.body(), self.fields), [])
        self.values["Notes"] = "x" * kickoff.MAX_HEADER
        failures = kickoff.validate(self.body(), self.fields)
        self.assertEqual(failures, [f for f in failures if "before Spec" in f])
        self.assertEqual(len(failures), 1)

    def test_in_bounds_and_acceptance(self):
        cases = {("In bounds", "the scroll code"): False,
                 ("In bounds", "core/ScrollArea.zig and callers"): False,
                 ("In bounds", "app/*.zig etc."): False,
                 ("In bounds", "`rg -l scrollArea app core`"): True,
                 ("In bounds", "build.zig, web/fizzy.js"): True,
                 ("Acceptance", "it works"): False,
                 ("Acceptance", "`scripts/zb build test` passes"): True}
        for (name, value), ok in cases.items():
            with self.subTest(name=name, value=value):
                saved, self.values[name] = self.values[name], value
                failures = kickoff.validate(self.body(), self.fields)
                self.assertEqual(not failures, ok, failures)
                self.values[name] = saved

    def test_spec_not_in_a_comment(self):
        for note in ("Spec in the first comment.", "See comments for the tests.", "spec is in a comment"):
            with self.subTest(note=note):
                self.values["Notes"] = note
                self.assertIn("Body: the spec must be in the body, not in a comment",
                              kickoff.validate(self.body(), self.fields))

    def test_template_fields_are_live(self):
        with tempfile.TemporaryDirectory() as directory:
            template = Path(directory) / "AGENT_WORK.md"
            template.write_text("## Kickoff template\n```\nExtra: value\n```\n")
            original = kickoff.TEMPLATE
            try:
                kickoff.TEMPLATE = template
                self.assertEqual(kickoff.template_fields(), ["Extra"])
                self.assertIn("Extra: missing field or empty value",
                              kickoff.validate("", kickoff.template_fields()))
            finally:
                kickoff.TEMPLATE = original

    def test_cli_file_and_issue(self):
        with tempfile.TemporaryDirectory() as directory:
            body = Path(directory) / "body"
            body.write_text(self.body())
            result = subprocess.run([str(SCRIPT), str(body)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            gh = Path(directory) / "gh"
            gh.write_text('#!/bin/sh\n[ "$*" = "issue view 7 --repo fizzyedit/work --json body --jq .body" ] || exit 9\ncat "$KICKOFF_BODY"\n')
            gh.chmod(0o755)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"], KICKOFF_BODY=str(body))
            result = subprocess.run([str(SCRIPT), "7"], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            body.write_text("Task: incomplete")
            result = subprocess.run([str(SCRIPT), str(body)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Branch:", result.stderr)
            gh.write_text('#!/bin/sh\nprintf "lookup failed\\n" >&2\nexit 1\n')
            result = subprocess.run([str(SCRIPT), "7"], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("lookup failed", result.stderr)
            result = subprocess.run([str(SCRIPT), str(body) + ".missing"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
