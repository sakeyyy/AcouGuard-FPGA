"""Offline board-evidence and generic register/performance tooling tests."""
import argparse
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skill/pynq-stream-validation/scripts"))
sys.path.insert(0, str(ROOT / "src/web"))
import measurement
from protocol import Parser, encode


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


observations = load("observations", ROOT / "board/scripts/compare_observations.py")
uart = load("uart_record", ROOT / "board/scripts/record_uart.py")


class SubmissionTests(unittest.TestCase):
    def rows(self):
        with (ROOT / "board/validation/video_comparison.csv").open(encoding="utf-8", newline="") as source:
            return list(csv.DictReader(source))

    def compare_rows(self, rows):
        with tempfile.TemporaryDirectory(dir=ROOT / "build/output") as temporary:
            path = Path(temporary) / "records.csv"
            with path.open("w", newline="", encoding="utf-8") as output:
                writer = csv.DictWriter(output, fieldnames=rows[0].keys())
                writer.writeheader()
                writer.writerows(rows)
            return observations.compare(path)

    def test_video_traceability(self):
        result = observations.compare(ROOT / "board/validation/video_comparison.csv")
        self.assertEqual(result["record_count"], 10)
        self.assertEqual(result["matching_observations"], 10)
        self.assertFalse(result["statistical_accuracy_computed"])
        self.assertFalse(result["complete_uart_log_available"])
        self.assertIn("board/evidence/onboard_demo.mp4", result["evidence_sha256"])

    def test_video_mismatch_retained(self):
        rows = self.rows()[:1]
        rows[0]["observed"] = "unexpected_output"
        result = self.compare_rows(rows)
        self.assertEqual(result["matching_observations"], 0)

    def test_invalid_evidence_rejected(self):
        rows = self.rows()[:1]
        with self.assertRaises(ValueError):
            self.compare_rows(rows * 2)
        for name in ("missing.mp4", "../README.md"):
            rows[0]["evidence"] = name
            with self.assertRaises(ValueError):
                self.compare_rows(rows)

    def test_uart_pcm_demultiplexing(self):
        events = []
        parser = Parser(uart.Lines(events.append).feed)
        payload = b"NameAlert: fake_pcm\n\x00"
        if len(payload) % 2:
            payload += b"\x00"
        samples = np.frombuffer(payload, dtype=np.int16)
        data = b"Sound: dog_bark\r\n" + encode(samples, 4000, 1, 7) + b"NameAlert: real_tag\r\n"
        packets = []
        for index in range(0, len(data), 3):
            packets.extend(parser.feed(data[index:index + 3]))
        self.assertEqual(len(packets), 1)
        self.assertEqual([event["type"] for event in events], ["recognition", "name_alert"])
        self.assertEqual(events[0]["label"], "dog_bark")
        self.assertEqual(events[1]["text"], "NameAlert: real_tag")

    def test_register_fields_hierarchy(self):
        registers = SimpleNamespace(S2MM_DMASR=SimpleNamespace(Idle=1, Halted=0))
        overlay = SimpleNamespace(sub=SimpleNamespace(dma=SimpleNamespace(register_map=registers)))
        result = measurement.inspect_registers(overlay, "sub/dma", ["S2MM_DMASR.Idle"])
        self.assertEqual(result["read_only_fields"], {"S2MM_DMASR.Idle": 1})
        with self.assertRaises(AttributeError):
            measurement.inspect_registers(overlay, "sub/dma", ["MISSING"])
        with self.assertRaises(ValueError):
            measurement.inspect_registers(overlay, "sub/dma", ["__dict__"])

    def test_warmup_and_performance_statistics(self):
        calls = []
        clock = iter([0., .1, 1., 1.2, 2., 2.3])
        golden = np.arange(4, dtype=np.int32)
        def transfer():
            calls.append(1)
            return golden.copy()
        result = measurement.benchmark(transfer, 3, 1, golden=golden, clock=lambda: next(clock),
                                       evidence="software_mock")
        self.assertTrue(result["passed"])
        self.assertEqual(len(calls), 4)
        self.assertEqual(result["warmup_completed"], 1)
        self.assertAlmostEqual(result["summary"]["median_s"], .2)
        self.assertAlmostEqual(result["summary"]["p95_s"], .29)
        self.assertAlmostEqual(result["summary"]["effective_payload_bytes_per_s"], 80.)

    def test_golden_failure(self):
        clock = iter([0., .1])
        result = measurement.benchmark(lambda: np.array([2], np.int32), 2, 0,
            golden=np.array([1], np.int32), clock=lambda: next(clock), evidence="software_mock")
        self.assertFalse(result["passed"])
        self.assertEqual(len(result["samples"]), 1)
        self.assertIn("Golden reference mismatch", result["error"])

    def test_failure_and_configuration(self):
        def failure():
            raise TimeoutError("synthetic timeout")
        result = measurement.benchmark(failure, 2, 1, evidence="software_mock")
        self.assertFalse(result["passed"])
        self.assertEqual(result["samples"], [])
        self.assertNotIn("summary", result)
        for iterations, warmup in ((0, 0), (1, -1), (True, 0)):
            with self.assertRaises(ValueError):
                measurement.benchmark(failure, iterations, warmup)

    def test_json_markdown_report(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build/output") as temporary:
            output = Path(temporary) / "mock.json"
            measurement.save_report(output, {"evidence": "software_mock", "passed": False, "error": "test error"})
            self.assertEqual(json.loads(output.read_text())["evidence"], "software_mock")
            self.assertIn("test error", output.with_suffix(".md").read_text())


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "sim/results/submission_additions.json")
    args = parser.parse_args()
    (ROOT / "build/output").mkdir(parents=True, exist_ok=True)
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(SubmissionTests))
    summary = {"evidence": "offline_software_regression", "hardware_tested": False,
               "tests": result.testsRun, "passed": result.wasSuccessful(),
               "failures": [str(test) for test, _ in result.failures],
               "errors": [str(test) for test, _ in result.errors],
               "measurement_script_sha256": hashlib.sha256(Path(measurement.__file__).read_bytes()).hexdigest()}
    args.output.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(0 if result.wasSuccessful() else 1)
