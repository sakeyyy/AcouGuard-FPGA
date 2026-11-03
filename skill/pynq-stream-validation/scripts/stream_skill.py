"""Contract-driven PYNQ simple-DMA helpers and offline verification tools."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import time
import xml.etree.ElementTree as ET

import numpy as np

QUARANTINED_BUFFERS = []


def number(value):
    return int(value, 0) if isinstance(value, str) else int(value)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def validate_contract(data):
    if data["schema_version"] != 1 or data["mode"] not in ("receive", "loopback"):
        raise ValueError("Unsupported schema or mode")
    dtype = np.dtype(data["dtype"])
    if dtype.kind not in "iuf" or dtype.itemsize not in (1, 2, 4, 8) or not dtype.isnative:
        raise ValueError("Native real numeric scalar dtype required")
    if dtype.kind == "f" and dtype.itemsize not in (4, 8):
        raise ValueError("Only float32/float64 supported")
    for key in ("frames", "channels", "valid_bits", "stream_width_bits",
                "dma_length_width", "dma_alignment"):
        if type(data[key]) is not int or data[key] <= 0:
            raise ValueError(key + " must be a positive integer")
    if not 1 <= data["valid_bits"] <= dtype.itemsize * 8:
        raise ValueError("Invalid valid_bits")
    if dtype.kind == "f" and data["valid_bits"] != dtype.itemsize * 8:
        raise ValueError("Floating point must use the full container")
    if data.get("signed_pcm", False) and dtype.kind != "i":
        raise ValueError("signed_pcm requires signed integer dtype")
    order = data["channel_order"]
    if (not isinstance(order, list) or len(order) != data["channels"]
            or any(not isinstance(item, str) or not item for item in order)
            or len(set(order)) != len(order)):
        raise ValueError("Unique channel_order must match channels")
    width = data["stream_width_bits"]
    align = data["dma_alignment"]
    if width < 8 or width > 512 or width & (width - 1) or align & (align - 1):
        raise ValueError("Stream width/alignment must be powers of two")
    if not 8 <= data["dma_length_width"] <= 26:
        raise ValueError("DMA length width must be 8..26")
    nbytes = data["frames"] * data["channels"] * dtype.itemsize
    if nbytes >= 2 ** data["dma_length_width"] or nbytes % (width // 8):
        raise ValueError("Packet exceeds DMA length or contains a partial beat")
    for key in ("name", "dma_ip", "bitfile", "hwh"):
        if not isinstance(data[key], str) or not data[key]:
            raise ValueError("Missing string " + key)
    if Path(data["bitfile"]).suffix != ".bit" or Path(data["hwh"]).suffix != ".hwh":
        raise ValueError("Expected .bit and .hwh, not XSA or NPZ")
    if Path(data["bitfile"]).with_suffix(".hwh") != Path(data["hwh"]):
        raise ValueError("BIT/HWH must share directory and stem for PYNQ discovery")
    for check in data.get("register_checks", []):
        if not isinstance(check["ip"], str) or not check["ip"]:
            raise ValueError("Invalid signature IP")
        offset, mask, expected = (number(check[key]) for key in ("offset", "mask", "expected"))
        if offset < 0 or offset % 4 or not 0 <= expected <= 0xffffffff or not 0 < mask <= 0xffffffff:
            raise ValueError("Invalid register check")
    return {"name": data["name"], "shape": [data["frames"], data["channels"]],
            "dtype": dtype.name, "nbytes": nbytes, "mode": data["mode"]}


def load_contract(path):
    path = Path(path).resolve()
    data = json.loads(path.read_text(encoding="utf-8"))
    validate_contract(data)
    data["_directory"] = str(path.parent)
    return data


def preflight(data):
    layout = validate_contract(data)
    directory = Path(data.get("_directory", "."))
    bitfile, hwh = (directory / data[key] for key in ("bitfile", "hwh"))
    if not bitfile.is_file() or not hwh.is_file():
        raise FileNotFoundError("Supply a same-export BIT/HWH pair: " + str(bitfile))
    modules = {}
    for module in ET.parse(hwh).iter("MODULE"):
        name = module.get("FULLNAME", module.get("INSTANCE", "")).strip("/")
        modules[name] = module
    name = data["dma_ip"].strip("/")
    if name not in modules:
        raise ValueError("DMA instance missing from HWH: " + name)
    module = modules[name]
    if ":axi_dma:" not in module.get("VLNV", ""):
        raise ValueError("Selected IP is not AXI DMA")
    params = {item.get("NAME"): item.get("VALUE") for item in module.iter("PARAMETER")}
    required = {"C_INCLUDE_SG": 0, "C_SG_LENGTH_WIDTH": data["dma_length_width"],
                "C_INCLUDE_S2MM": 1, "C_S_AXIS_S2MM_TDATA_WIDTH": data["stream_width_bits"]}
    if data["mode"] == "loopback":
        required.update(C_INCLUDE_MM2S=1, C_M_AXIS_MM2S_TDATA_WIDTH=data["stream_width_bits"])
    for key, expected in required.items():
        if key not in params or number(params[key]) != expected:
            raise ValueError("HWH mismatch or missing parameter: " + key)
    layout.update(bit_sha256=sha256(bitfile), hwh_sha256=sha256(hwh),
                  dma_ip=name, evidence="offline_metadata_check")
    return layout


def resolve_ip(overlay, name):
    current = overlay
    for component in name.strip("/").split("/"):
        current = getattr(current, component)
    return current


def open_overlay(data):
    preflight(data)
    from pynq import Overlay
    overlay = Overlay(str(Path(data.get("_directory", ".")) / data["bitfile"]))
    dma = resolve_ip(overlay, data["dma_ip"])
    for check in data.get("register_checks", []):
        actual = resolve_ip(overlay, check["ip"]).read(number(check["offset"]))
        mask = number(check["mask"])
        if actual & mask != number(check["expected"]) & mask:
            raise RuntimeError("Hardware signature mismatch at " + check["ip"])
    return overlay, dma


def validate_array(array, data):
    spec = validate_contract(data)
    if list(array.shape) != spec["shape"] or array.dtype != np.dtype(data["dtype"]):
        raise ValueError("Array shape/dtype violates contract")
    if not np.isfinite(array).all():
        raise ValueError("Nonfinite array")
    if data.get("signed_pcm", False):
        limit = 2 ** (data["valid_bits"] - 1)
        if np.any(array < -limit) or np.any(array >= limit):
            raise ValueError("PCM not sign extended/right aligned to valid_bits")


def receive_once(dma, data, source=None, timeout_s=2.0, start=None, stop=None, allocator=None):
    spec = validate_contract(data)
    if not np.isfinite(timeout_s) or timeout_s <= 0:
        raise ValueError("Positive finite timeout required")
    if (source is None) != (data["mode"] == "receive"):
        raise ValueError("Source required only for loopback")
    if source is not None:
        source = np.asarray(source)
        validate_array(source, data)
    if allocator is None:
        from pynq import allocate
        allocator = allocate
    buffers, channels = [], []
    receive_buffer = None
    started_source = False
    success = False
    try:
        receive_buffer = allocator(shape=tuple(spec["shape"]), dtype=np.dtype(data["dtype"]))
        buffers.append(receive_buffer)
        if receive_buffer.device_address % data["dma_alignment"]:
            raise ValueError("Unaligned RX device address")
        transmit_buffer = None
        if source is not None:
            transmit_buffer = allocator(shape=tuple(spec["shape"]), dtype=source.dtype)
            buffers.append(transmit_buffer)
            if transmit_buffer.device_address % data["dma_alignment"]:
                raise ValueError("Unaligned TX device address")
            transmit_buffer[:] = source
            transmit_buffer.flush()
        receive_buffer.flush()
        channels.append((dma.recvchannel, 0x34))
        dma.recvchannel.transfer(receive_buffer, nbytes=spec["nbytes"])
        if transmit_buffer is not None:
            channels.append((dma.sendchannel, 0x04))
            dma.sendchannel.transfer(transmit_buffer, nbytes=spec["nbytes"])
        if start is not None:
            started_source = True
            start()
        deadline = time.monotonic() + timeout_s
        while True:
            statuses = [dma.read(offset) for _, offset in channels]
            if any(status & 0x770 for status in statuses):
                raise RuntimeError("DMA status error: " + repr(statuses))
            if all(channel.idle for channel, _ in channels):
                break
            if time.monotonic() >= deadline:
                raise TimeoutError("DMA timeout: inspect TLAST, clocks, reset and length")
            time.sleep(0.001)
        transferred = dma.read(0x58)
        if transferred != spec["nbytes"]:
            raise RuntimeError("S2MM short/long packet: " + str(transferred))
        for channel, _ in channels:
            channel.wait()
        receive_buffer.invalidate()
        result = np.array(receive_buffer, copy=True)
        validate_array(result, data)
        success = True
        return result
    finally:
        cleanup_error = None
        if started_source and stop is not None:
            try:
                stop()
            except Exception as error:
                cleanup_error = error
        halted = True
        if not success:
            for channel, status_offset in channels:
                try:
                    control_offset = status_offset - 4
                    dma.write(control_offset, dma.read(control_offset) & ~1)
                    deadline = time.monotonic() + 0.1
                    while not dma.read(status_offset) & 1:
                        if time.monotonic() >= deadline:
                            raise TimeoutError("Cannot halt DMA")
                        time.sleep(0.001)
                except Exception as error:
                    halted = False
                    cleanup_error = error
        if halted:
            for buffer in buffers:
                buffer.freebuffer()
        else:
            QUARANTINED_BUFFERS.extend(buffers)
        if cleanup_error is not None:
            raise RuntimeError("Cleanup failed; stop source/reload Overlay before retry. "
                               "Unhalted DMA buffers retained.") from cleanup_error


def compare_arrays(expected, actual, atol=0.0, rtol=0.0, contract=None):
    if not all(np.isfinite(value) and value >= 0 for value in (atol, rtol)):
        raise ValueError("Finite nonnegative tolerances required")
    if expected.shape != actual.shape or expected.dtype != actual.dtype or expected.size == 0:
        raise ValueError("Golden shape/dtype mismatch or empty input")
    if expected.dtype.kind not in "iuf" or not np.isfinite(expected).all() or not np.isfinite(actual).all():
        raise ValueError("Real finite numeric arrays required")
    if contract is not None:
        validate_array(expected, contract)
        validate_array(actual, contract)
    if expected.dtype.kind in "iu":
        matches = expected == actual
        maximum = max(abs(int(left) - int(right)) for left, right in zip(expected.flat, actual.flat))
    else:
        matches = np.isclose(actual, expected, atol=atol, rtol=rtol)
        maximum = float(np.max(np.abs(actual.astype(np.float64) - expected.astype(np.float64))))
    return {"passed": bool(matches.all()), "samples": int(expected.size),
            "mismatches": int(np.count_nonzero(~matches)), "max_abs_error": maximum,
            "comparison": "integer_exact" if expected.dtype.kind in "iu" else "float_tolerance",
            "atol": atol, "rtol": rtol}


def parse_reports(utilization, timing):
    resources = {}
    names = {"Slice LUTs": "lut", "Slice Registers": "ff", "Block RAM Tile": "bram", "DSPs": "dsp"}
    for line in Path(utilization).read_text(encoding="utf-8", errors="replace").splitlines():
        cells = [item.strip() for item in line.split("|")]
        if len(cells) >= 7 and cells[1].rstrip("*") in names:
            resources[names[cells[1].rstrip("*")]] = {
                "used": float(cells[2]), "available": float(cells[5]),
                "percent": float(cells[6].rstrip("%"))}
    if set(resources) != set(names.values()):
        raise ValueError("Unsupported utilization report: missing required rows")
    text = Path(timing).read_text(encoding="utf-8", errors="replace")
    section = text.split("Design Timing Summary", 1)[-1]
    match = re.search(r"^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+\d+\s+\d+\s+"
                      r"(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+\d+\s+\d+\s+"
                      r"(-?\d+\.\d+)\s+(-?\d+\.\d+)", section, re.MULTILINE)
    if not match:
        raise ValueError("Unsupported timing report: missing numeric summary")
    metrics = dict(zip(("wns_ns", "tns_ns", "whs_ns", "ths_ns", "wpws_ns", "tpws_ns"),
                       map(float, match.groups())))
    warnings = {}
    for key in ("no_input_delay", "no_output_delay", "unconstrained_internal_endpoints"):
        found = re.search(re.escape(key) + r"\s*\((\d+)\)", text)
        if not found:
            raise ValueError("Missing timing coverage field: " + key)
        warnings[key] = int(found.group(1))
    return {"evidence": "implementation_report_not_board_measurement",
            "resources": resources, "timing": metrics, "constraint_warnings": warnings,
            "source_sha256": {"utilization": sha256(utilization), "timing": sha256(timing)}}


def generate(data, output):
    output = Path(output)
    if output.exists() and any(output.iterdir()):
        raise FileExistsError("Refusing nonempty output directory")
    output.mkdir(parents=True, exist_ok=True)
    exported = {key: value for key, value in data.items() if not key.startswith("_")}
    exported["bitfile"] = Path(data["bitfile"]).name
    exported["hwh"] = Path(data["hwh"]).name
    write_json(output / "contract.json", exported)
    shutil.copyfile(__file__, output / "stream_skill.py")
    (output / "run.py").write_text(
        'from pathlib import Path\nimport argparse\nimport numpy as np\n'
        'from stream_skill import load_contract, open_overlay, receive_once\n'
        'p = argparse.ArgumentParser()\np.add_argument("--input")\n'
        'p.add_argument("--timeout", type=float, default=2.0)\na = p.parse_args()\n'
        'root = Path(__file__).resolve().parent\nc = load_contract(root / "contract.json")\n'
        'source = np.load(a.input, allow_pickle=False) if a.input else None\n'
        'overlay, dma = open_overlay(c)\nprint(dma.register_map)\n'
        'received = receive_once(dma, c, source=source, timeout_s=a.timeout)\n'
        'np.save(root / "received.npy", received)\n', encoding="utf-8")
    (output / "test_reference.py").write_text(
        'from pathlib import Path\nimport numpy as np\n'
        'from stream_skill import compare_arrays, load_contract\n'
        'root = Path(__file__).resolve().parent\n'
        'golden = np.load(root / "golden.npy", allow_pickle=False)\n'
        'actual = np.load(root / "received.npy", allow_pickle=False)\n'
        'result = compare_arrays(golden, actual, contract=load_contract(root / "contract.json"))\n'
        'print(result)\nraise SystemExit(0 if result["passed"] else 1)\n', encoding="utf-8")
    notebook = {"nbformat": 4, "nbformat_minor": 5,
                "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python",
                                          "name": "python3"}}, "cells": []}
    code_cells = [
        "from stream_skill import load_contract, preflight, open_overlay, receive_once, compare_arrays\n"
        "import numpy as np\ncontract = load_contract('contract.json')\npreflight(contract)",
        "overlay, dma = open_overlay(contract)\nprint(dma.register_map)",
        "source = np.load('input.npy', allow_pickle=False) if contract['mode'] == 'loopback' else None\n"
        "received = receive_once(dma, contract, source=source, timeout_s=2.0)\n"
        "np.save('received.npy', received)",
        "golden = np.load('golden.npy', allow_pickle=False)\n"
        "result = compare_arrays(golden, received, contract=contract)\n"
        "print(result)\nassert result['passed']"]
    notebook["cells"].append({"cell_type": "markdown", "metadata": {},
                             "source": ["# Fixed-length PYNQ DMA validation\n",
                                        "Supply same-export BIT/HWH and independent golden.npy.\n",
                                        "Adapt start/stop callbacks before sensor acquisition."]})
    for index, code in enumerate(code_cells):
        notebook["cells"].append({"cell_type": "code", "id": "validation-" + str(index),
                                 "execution_count": None, "metadata": {}, "outputs": [],
                                 "source": code.splitlines(keepends=True)})
    notebook["cells"][0]["id"] = "introduction"
    write_json(output / "validate.ipynb", notebook)
    return {"generated": str(output), "hardware_files_copied": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("contract", "preflight", "generate"):
        sub = commands.add_parser(name)
        sub.add_argument("contract")
        if name == "generate":
            sub.add_argument("--output", required=True)
    sub = commands.add_parser("compare")
    sub.add_argument("golden")
    sub.add_argument("actual")
    sub.add_argument("--contract")
    sub.add_argument("--atol", type=float, default=0.0)
    sub.add_argument("--rtol", type=float, default=0.0)
    sub = commands.add_parser("reports")
    sub.add_argument("--utilization", required=True)
    sub.add_argument("--timing", required=True)
    sub.add_argument("--baseline")
    sub.add_argument("--output", required=True)
    args = parser.parse_args()
    if args.command in ("contract", "preflight", "generate"):
        data = load_contract(args.contract)
        result = (validate_contract(data) if args.command == "contract" else
                  preflight(data) if args.command == "preflight" else generate(data, args.output))
    elif args.command == "compare":
        result = compare_arrays(np.load(args.golden, allow_pickle=False),
                                np.load(args.actual, allow_pickle=False), args.atol, args.rtol,
                                load_contract(args.contract) if args.contract else None)
        result["source_sha256"] = {"golden": sha256(args.golden), "actual": sha256(args.actual)}
    else:
        result = parse_reports(args.utilization, args.timing)
        if args.baseline:
            baseline = json.loads(Path(args.baseline).read_text(encoding="utf-8"))
            result["baseline_sha256"] = sha256(args.baseline)
            result["delta_used"] = {key: value["used"] - baseline["resources"][key]["used"]
                                    for key, value in result["resources"].items()}
            result["delta_wns_ns"] = result["timing"]["wns_ns"] - baseline["timing"]["wns_ns"]
            result["baseline_conditions_verified_by_tool"] = False
        write_json(args.output, result)
    print(json.dumps(result, indent=2))
    return 0 if result.get("passed", True) else 1


if __name__ == "__main__":
    raise SystemExit(main())
