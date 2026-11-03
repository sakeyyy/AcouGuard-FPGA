"""Read PYNQ register_map fields and measure real host-side DMA calls."""
import argparse
from datetime import datetime, timezone
import importlib.metadata
import json
from pathlib import Path
import time

import numpy as np

from stream_skill import (compare_arrays, load_contract, open_overlay, preflight,
                          receive_once, resolve_ip, validate_array, write_json)


def inspect_registers(overlay, ip_name, fields):
    ip = resolve_ip(overlay, ip_name)
    register_map = ip.register_map
    values = {}
    for name in fields:
        if not name or name.startswith("_") or any(not component.isidentifier() or
                                                  component.startswith("_")
                                                  for component in name.split(".")):
            raise ValueError("Public register.field names required")
        current = register_map
        for component in name.split("."):
            current = getattr(current, component)
        values[name] = int(current)
    return {"ip": ip_name, "register_map": str(register_map), "read_only_fields": values}


def benchmark(transfer, iterations=10, warmup=2, golden=None, contract=None,
              clock=time.perf_counter, evidence="pynq_host_dma_measurement"):
    if type(iterations) is not int or iterations <= 0 or type(warmup) is not int or warmup < 0:
        raise ValueError("Positive iterations and nonnegative warmup required")
    report = {"evidence": evidence, "clock_scope": "host_call_including_allocation_cache_trigger_copy",
              "iterations_requested": iterations, "warmup_requested": warmup,
              "warmup_completed": 0, "samples": [], "passed": False,
              "utc": datetime.now(timezone.utc).isoformat()}
    import hashlib
    try:
        for _ in range(warmup):
            transfer()
            report["warmup_completed"] += 1
        for index in range(iterations):
            start = clock()
            actual = transfer()
            elapsed = clock() - start
            if not np.isfinite(elapsed) or elapsed <= 0:
                raise ValueError("Invalid monotonic duration")
            if contract is not None:
                validate_array(actual, contract)
            sample = {"iteration": index, "elapsed_s": elapsed, "payload_bytes": actual.nbytes,
                      "output_sha256": hashlib.sha256(actual.tobytes()).hexdigest()}
            report["samples"].append(sample)
            if golden is not None:
                sample["golden"] = compare_arrays(golden, actual, contract=contract)
                if not sample["golden"]["passed"]:
                    raise RuntimeError("Golden reference mismatch")
        report["passed"] = True
    except Exception as error:
        report["error"] = repr(error)
    durations = np.array([sample["elapsed_s"] for sample in report["samples"]], dtype=float)
    if durations.size:
        report["summary"] = {"completed": len(durations), "median_s": float(np.median(durations)),
                             "p95_s": float(np.percentile(durations, 95)),
                             "min_s": float(durations.min()), "max_s": float(durations.max()),
                             "effective_payload_bytes_per_s": sum(sample["payload_bytes"] for sample in
                                                                 report["samples"]) / float(durations.sum())}
    return report


def save_report(path, report):
    write_json(path, report)
    lines = ["# PYNQ Host Measurement", "", "Evidence: " + report["evidence"], "",
             "Scope: host call including allocation/cache/trigger/copy, NOT isolated PL kernel latency.", "",
             "Passed: " + str(report["passed"]), "", "~~~json",
             json.dumps(report.get("summary", {}), indent=2), "~~~", ""]
    if "error" in report:
        lines += ["Error: " + report["error"], ""]
    Path(path).with_suffix(".md").write_text("\n".join(lines), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("registers", "benchmark"):
        command = sub.add_parser(name)
        command.add_argument("contract", type=Path)
        command.add_argument("--output", type=Path, required=True)
        if name == "registers":
            command.add_argument("--ip", required=True)
            command.add_argument("--field", action="append", default=[])
        else:
            command.add_argument("--input", type=Path, required=True)
            command.add_argument("--golden", type=Path)
            command.add_argument("--iterations", type=int, default=10)
            command.add_argument("--warmup", type=int, default=2)
            command.add_argument("--timeout", type=float, default=2)
    args = parser.parse_args()
    contract = load_contract(args.contract)
    metadata = preflight(contract)
    if args.output.exists() or (args.command == "benchmark" and args.output.with_suffix(".md").exists()):
        raise FileExistsError("Do not overwrite measurement evidence")
    source = golden = None
    if args.command == "benchmark":
        if contract["mode"] != "loopback":
            raise ValueError("CLI benchmark requires loopback; use API with trigger callbacks for capture")
        if args.iterations <= 0 or args.warmup < 0 or not np.isfinite(args.timeout) or args.timeout <= 0:
            raise ValueError("Invalid measurement configuration")
        source = np.load(args.input, allow_pickle=False)
        validate_array(source, contract)
        golden = np.load(args.golden, allow_pickle=False) if args.golden else None
        if golden is not None:
            validate_array(golden, contract)
    overlay, dma = open_overlay(contract)
    try:
        version = importlib.metadata.version("pynq")
    except importlib.metadata.PackageNotFoundError:
        version = "unknown"
    if args.command == "registers":
        result = inspect_registers(overlay, args.ip, args.field)
        result.update(evidence="pynq_register_map_read", preflight=metadata, pynq_version=version)
        write_json(args.output, result)
    else:
        result = benchmark(lambda: receive_once(dma, contract, source=source, timeout_s=args.timeout),
                           args.iterations, args.warmup, golden, contract)
        result.update(preflight=metadata, pynq_version=version,
                      source_sha256=__import__("hashlib").sha256(args.input.read_bytes()).hexdigest(),
                      golden_sha256=__import__("hashlib").sha256(args.golden.read_bytes()).hexdigest()
                      if args.golden else None)
        save_report(args.output, result)
    print(json.dumps(result, indent=2))
    return 0 if result.get("passed", True) else 1


if __name__ == "__main__":
    raise SystemExit(main())
