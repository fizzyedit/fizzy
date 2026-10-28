#!/usr/bin/env python3
"""Fault-inject the demo watchdog without bringing up the whole editor."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class DemoWatchdogTests(unittest.TestCase):
    def test_blocked_phase_names_test_and_phase(self):
        result = self.run_watchdog(
            '''try Watchdog.start();
    Watchdog.enter("injected blocked frame");
    var blocked: std.Io.Event = .unset;
    blocked.wait(std.testing.io) catch unreachable;'''
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("test 'injected demo test'", result.stdout)
        self.assertIn("phase 'injected blocked frame'", result.stdout)
        self.assertIn("aborting", result.stdout)

    def test_stop_wakes_and_joins_watchdog(self):
        result = self.run_watchdog(
            '''try Watchdog.start();
    Watchdog.stop();
    try Watchdog.start();
    Watchdog.stop();'''
        )
        self.assertEqual(result.returncode, 0, result.stdout)

    def run_watchdog(self, body):
        # Compile the implementation itself; a copied watchdog could pass while the real one hangs.
        source = (ROOT / "tests/demos.zig").read_text()
        start = source.index("const Watchdog = struct {")
        end = source.index("\n};", start) + len("\n};")
        watchdog = source[start:end].replace("const limit_ms = 180_000;", "const limit_ms = 500;")
        watchdog = watchdog.replace("const poll_ms = 1000;", "const poll_ms = 10;")
        self.assertNotIn("180_000", watchdog)
        with tempfile.TemporaryDirectory(prefix="fizzy-demo-watchdog-") as directory:
            path = pathlib.Path(directory)
            zig = path / "watchdog.zig"
            binary = path / "watchdog"
            zig.write_text(
                'const std = @import("std");\n'
                'const bundled_test_name = "injected demo test";\n'
                + watchdog
                + '\ntest "watchdog fault injection" {\n    '
                + body
                + "\n}\n"
            )
            subprocess.run(
                ["zig", "test", str(zig), "--test-no-exec", f"-femit-bin={binary}"],
                check=True, capture_output=True, text=True, timeout=120,
            )
            # A broken watchdog must fail this check, rather than hang the gate running it.
            return subprocess.run(
                [str(binary)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, timeout=5, cwd=path,
            )


if __name__ == "__main__":
    unittest.main()
