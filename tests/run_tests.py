"""Minimal test runner. Run with `python3 tests/run_tests.py`.

The runner does not require pytest. It discovers every `test_*.py`
file under `tests/` and runs them via `unittest`.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def main() -> int:
    loader = unittest.TestLoader()
    suite = loader.discover(start_dir=str(ROOT / "tests"),
                            pattern="test_*.py",
                            top_level_dir=str(ROOT))
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())