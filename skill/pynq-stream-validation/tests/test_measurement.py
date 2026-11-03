"""Standalone measurement helper tests; simulated timing, no PYNQ hardware."""
import argparse
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from measurement import benchmark, inspect_registers


class MeasurementTests(unittest.TestCase):
    def test_hierarchical_register_fields(self):
        registers = SimpleNamespace(STATUS=SimpleNamespace(Ready=1))
        overlay = SimpleNamespace(group=SimpleNamespace(core=SimpleNamespace(register_map=registers)))
        result = inspect_registers(overlay, "group/core", ["STATUS.Ready"])
        self.assertEqual(result["read_only_fields"]["STATUS.Ready"], 1)
        with self.assertRaises(AttributeError):
            inspect_registers(overlay, "group/core", ["STATUS.Missing"])
        with self.assertRaises(ValueError):
            inspect_registers(overlay, "group/core", ["__class__"])

    def test_warmup_exclusion_and_statistics(self):
        clock = iter([0., .1, 1., 1.2, 2., 2.3])
        calls = []
        array = np.arange(4, dtype=np.int32)
        def transfer():
            calls.append(1)
            return array.copy()
        result = benchmark(transfer, 3, 2, golden=array, clock=lambda: next(clock), evidence="software_mock")
        self.assertTrue(result["passed"])
        self.assertEqual(len(calls), 5)
        self.assertAlmostEqual(result["summary"]["median_s"], .2)
        self.assertAlmostEqual(result["summary"]["p95_s"], .29)
        self.assertAlmostEqual(result["summary"]["effective_payload_bytes_per_s"], 80.)

    def test_golden_mismatch_reported(self):
        clock = iter([0., 1.])
        result = benchmark(lambda: np.array([1], np.int32), 1, 0,
                           golden=np.array([2], np.int32), clock=lambda: next(clock),
                           evidence="software_mock")
        self.assertFalse(result["passed"])
        self.assertEqual(result["samples"][0]["golden"]["mismatches"], 1)

    def test_timeout_and_bad_clock_reported(self):
        def failure():
            raise TimeoutError("mock only")
        result = benchmark(failure, 1, 1, evidence="software_mock")
        self.assertFalse(result["passed"])
        self.assertEqual(result["warmup_completed"], 0)
        result = benchmark(lambda: np.ones(1), 1, 0, clock=lambda: 1., evidence="software_mock")
        self.assertFalse(result["passed"])
        self.assertIn("Invalid monotonic duration", result["error"])

    def test_bad_configuration(self):
        with self.assertRaises(ValueError):
            benchmark(lambda: np.ones(1), 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(MeasurementTests))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({"evidence": "software_mock_not_pynq_hardware",
            "tests": result.testsRun, "passed": result.wasSuccessful(), "hardware_tested": False},
            indent=2) + "\n", encoding="utf-8")
    raise SystemExit(0 if result.wasSuccessful() else 1)
