"""Offline tests: synthetic HWH and software DMA doubles, not board tests."""
import argparse
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import stream_skill as skill


class Buffer(np.ndarray):
    def __new__(cls, shape, dtype, events):
        instance = np.zeros(shape, dtype=dtype).view(cls)
        instance.events = events
        instance.device_address = 0x1000
        instance.freed = False
        return instance

    def flush(self):
        self.events.append("flush")

    def invalidate(self):
        self.events.append("invalidate")

    def freebuffer(self):
        self.freed = True
        self.events.append("free")


class Channel:
    def __init__(self, owner, name):
        self.owner, self.name = owner, name
        self.buffer = None

    def transfer(self, buffer, nbytes):
        self.owner.events.append(self.name)
        self.buffer = buffer
        self.owner.length = nbytes
        if self.name == "tx":
            self.owner.recvchannel.buffer[:] = buffer
        else:
            buffer[:] = 7

    @property
    def idle(self):
        return not self.owner.timeout

    def wait(self):
        self.owner.events.append("wait_" + self.name)


class DMA:
    def __init__(self, events, timeout=False, error=False, short=False, halt_failure=False):
        self.events = events
        self.timeout, self.error, self.short = timeout, error, short
        self.halt_failure = halt_failure
        self.halted = False
        self.length = 0
        self.recvchannel, self.sendchannel = Channel(self, "rx"), Channel(self, "tx")

    def read(self, offset):
        if offset == 0x58:
            return self.length - 4 if self.short else self.length
        if offset in (0x30, 0):
            return 1
        return (1 if self.halted else 0) | (0x20 if self.error else 0)

    def write(self, offset, value):
        self.events.append("stop")
        if not self.halt_failure:
            self.halted = True


class SkillTests(unittest.TestCase):
    def setUp(self):
        self.contract = skill.load_contract(ROOT / "examples/loopback.json")

    def assert_reject(self, change):
        data = copy.deepcopy(self.contract)
        data.update(change)
        with self.assertRaises((ValueError, KeyError, TypeError)):
            skill.validate_contract(data)

    def test_contracts_and_audio_bytes(self):
        for path in (ROOT / "examples").glob("*.json"):
            skill.validate_contract(skill.load_contract(path))
        audio = skill.load_contract(ROOT / "examples/project_audio.json")
        self.assertEqual(skill.validate_contract(audio)["nbytes"], 195328)

    def test_contract_rejections(self):
        for change in ({"frames": 1000000}, {"channels": 2}, {"dtype": "complex64"},
                       {"valid_bits": 33}, {"stream_width_bits": 24}, {"frames": True},
                       {"mode": "sg"}, {"hwh": "other.hwh"}, {"dma_alignment": 3},
                       {"dtype": "uint32", "signed_pcm": True}, {"dma_length_width": 100}):
            self.assert_reject(change)

    def fixture(self, directory, hierarchical=False):
        data = copy.deepcopy(self.contract)
        if hierarchical:
            data = skill.load_contract(ROOT / "examples/capture.json")
        data["_directory"] = str(directory)
        (directory / data["bitfile"]).write_bytes(b"SYNTHETIC-NOT-A-BITSTREAM")
        params = {"C_INCLUDE_SG": 0, "C_SG_LENGTH_WIDTH": data["dma_length_width"],
                  "C_INCLUDE_S2MM": 1, "C_INCLUDE_MM2S": 1,
                  "C_S_AXIS_S2MM_TDATA_WIDTH": 32, "C_M_AXIS_MM2S_TDATA_WIDTH": 32}
        parameters = "".join('<PARAMETER NAME="' + key + '" VALUE="' + str(value) + '"/>'
                             for key, value in params.items())
        xml = ('<ROOT><MODULE FULLNAME="/' + data["dma_ip"] +
               '" VLNV="xilinx.com:ip:axi_dma:7.1"><PARAMETERS>' +
               parameters + '</PARAMETERS></MODULE></ROOT>')
        (directory / data["hwh"]).write_text(xml, encoding="utf-8")
        return data

    def test_metadata_and_hierarchy(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for hierarchical in (False, True):
                data = self.fixture(directory, hierarchical)
                self.assertEqual(skill.preflight(data)["dma_ip"], data["dma_ip"])

    def test_metadata_rejections(self):
        with tempfile.TemporaryDirectory() as temporary:
            data = self.fixture(Path(temporary))
            path = Path(temporary) / data["hwh"]
            original = path.read_text()
            for old, new in (('C_INCLUDE_SG" VALUE="0', 'C_INCLUDE_SG" VALUE="1'),
                             ('C_SG_LENGTH_WIDTH" VALUE="14', 'C_SG_LENGTH_WIDTH" VALUE="13'),
                             (":axi_dma:", ":axi_gpio:"),
                             ('C_INCLUDE_S2MM" VALUE="1', 'C_INCLUDE_S2MM" VALUE="0')):
                path.write_text(original.replace(old, new))
                with self.assertRaises(ValueError):
                    skill.preflight(data)

    def test_golden_integer_exact_and_float_tolerance(self):
        integer = np.array([2**63 - 1, -2**63], dtype=np.int64)
        self.assertTrue(skill.compare_arrays(integer, integer.copy())["passed"])
        changed = integer.copy()
        changed[0] -= 1
        self.assertEqual(skill.compare_arrays(integer, changed, atol=99)["mismatches"], 1)
        self.assertEqual(skill.compare_arrays(integer, changed)["max_abs_error"], 1)
        expected = np.array([1.0], dtype=np.float32)
        actual = expected + np.float32(1e-6)
        self.assertTrue(skill.compare_arrays(expected, actual, atol=2e-6)["passed"])
        self.assertFalse(skill.compare_arrays(expected, actual)["passed"])

    def test_golden_invalid_inputs(self):
        expected = np.array([1.0], dtype=np.float32)
        for actual in (expected.astype(np.float64), expected.reshape(1, 1),
                       np.array([np.nan], dtype=np.float32), np.array([np.inf], dtype=np.float32)):
            with self.assertRaises(ValueError):
                skill.compare_arrays(expected, actual)
        with self.assertRaises(ValueError):
            skill.compare_arrays(expected, expected, atol=float("nan"))

    def test_pcm_sign_extension(self):
        contract = skill.load_contract(ROOT / "examples/project_audio.json")
        array = np.zeros((12208, 4), dtype=np.int32)
        array[0, 0] = -8388608
        skill.validate_array(array, contract)
        array[0, 0] = 8388608
        with self.assertRaises(ValueError):
            skill.validate_array(array, contract)

    def execute(self, **flags):
        events, buffers = [], []
        dma = DMA(events, **flags)

        def allocate(shape, dtype):
            buffer = Buffer(shape, dtype, events)
            buffers.append(buffer)
            return buffer

        source = np.arange(256, dtype=np.int32).reshape(256, 1)
        return dma, events, buffers, allocate, source

    def test_loopback_order_cache_and_cleanup(self):
        dma, events, buffers, allocate, source = self.execute()
        actual = skill.receive_once(dma, self.contract, source, allocator=allocate)
        self.assertTrue(np.array_equal(actual, source))
        self.assertLess(events.index("rx"), events.index("tx"))
        self.assertLess(events.index("flush"), events.index("tx"))
        self.assertLess(events.index("invalidate"), events.index("free"))
        self.assertTrue(all(buffer.freed for buffer in buffers))

    def test_capture_callbacks(self):
        dma, events, buffers, allocate, _ = self.execute()
        contract = skill.load_contract(ROOT / "examples/capture.json")
        actual = skill.receive_once(dma, contract, allocator=allocate,
                                    start=lambda: events.append("arm"),
                                    stop=lambda: events.append("disarm"))
        self.assertEqual(actual.shape, (128, 2))
        self.assertLess(events.index("rx"), events.index("arm"))
        self.assertLess(events.index("disarm"), events.index("free"))

    def test_timeout_error_short_packet(self):
        for flags, exception in (({"timeout": True}, TimeoutError), ({"error": True}, RuntimeError),
                                 ({"short": True}, RuntimeError)):
            dma, events, buffers, allocate, source = self.execute(**flags)
            with self.assertRaises(exception):
                skill.receive_once(dma, self.contract, source, timeout_s=0.002, allocator=allocate)
            self.assertIn("stop", events)
            self.assertTrue(all(buffer.freed for buffer in buffers))

    def test_unhalted_buffers_not_freed(self):
        dma, _, buffers, allocate, source = self.execute(timeout=True, halt_failure=True)
        count = len(skill.QUARANTINED_BUFFERS)
        with self.assertRaisesRegex(RuntimeError, "retained"):
            skill.receive_once(dma, self.contract, source, timeout_s=0.001, allocator=allocate)
        self.assertTrue(all(not buffer.freed for buffer in buffers))
        self.assertEqual(len(skill.QUARANTINED_BUFFERS), count + len(buffers))
        del skill.QUARANTINED_BUFFERS[count:]

    def test_generation_standalone_and_nonoverwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "generated"
            skill.generate(self.contract, output)
            for name in ("run.py", "test_reference.py", "stream_skill.py"):
                compile((output / name).read_text(), str(output / name), "exec")
            skill.load_contract(output / "contract.json")
            notebook = json.loads((output / "validate.ipynb").read_text())
            self.assertEqual(notebook["nbformat"], 4)
            for cell in notebook["cells"]:
                if cell["cell_type"] == "code":
                    compile("".join(cell["source"]), "notebook_cell", "exec")
                    self.assertEqual(cell["outputs"], [])
            with self.assertRaises(FileExistsError):
                skill.generate(self.contract, output)

    def test_report_parser_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            utilization = root / "util.rpt"
            timing = root / "time.rpt"
            utilization.write_text("\n".join("| " + name + " | 1 | 0 | 0 | 100 | 1 |"
                                             for name in ("Slice LUTs", "Slice Registers",
                                                          "Block RAM Tile", "DSPs")))
            timing.write_text("Design Timing Summary\n0.1 0.0 0 20 0.2 0.0 0 20 1.0 0.0\n"
                              "no_input_delay (2)\nno_output_delay (3)\n"
                              "unconstrained_internal_endpoints (0)")
            result = skill.parse_reports(utilization, timing)
            self.assertEqual(result["timing"]["wns_ns"], 0.1)
            self.assertEqual(result["constraint_warnings"]["no_output_delay"], 3)
            timing.write_text("Unknown format")
            with self.assertRaises(ValueError):
                skill.parse_reports(utilization, timing)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output")
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SkillTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if args.output:
        skill.write_json(args.output, {"evidence": "software_mock_not_pynq_hardware",
                                     "tests": result.testsRun, "passed": result.wasSuccessful(),
                                     "failures": [str(test) for test, _ in result.failures],
                                     "errors": [str(test) for test, _ in result.errors],
                                     "hardware_tested": False,
                                     "runtime_sha256": skill.sha256(ROOT / "scripts/stream_skill.py")})
    raise SystemExit(0 if result.wasSuccessful() else 1)
