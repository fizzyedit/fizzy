"""Gate entry: `python3 scripts/slot/tests/test_cleanup.py` runs test_slot_run_cleanup."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from slot.tests.test_slot_run_cleanup import CleanupRunTests, RemoveCheckoutTests  # noqa: E402,F401

if __name__ == '__main__':
    unittest.main()
