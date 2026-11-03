"""Run real source RTL with Vivado xsim; never reports a skipped tool as passed."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vivado-bin", type=Path)
    args = parser.parse_args()
    executable = (args.vivado_bin / "xvlog.bat" if args.vivado_bin else
                  Path(shutil.which("xvlog") or shutil.which("xvlog.bat") or "missing"))
    if not executable.is_file():
        raise FileNotFoundError("Load Vivado environment or provide --vivado-bin")
    tools = executable.resolve().parent
    source = ROOT / "src/vivado/test/test.srcs/sources_1/rtl/pcm_axis_packetizer.sv"
    testbench = ROOT / "sim/rtl/tb_packetizer.sv"
    banner = ROOT / "src/vivado/test/test.srcs/sources_1/rtl/name_call_banner.v"
    banner_test = ROOT / "sim/rtl/tb_name_banner.sv"
    output = ROOT / "sim/results"
    output.mkdir(exist_ok=True)
    work = ROOT / "build/output"
    work.mkdir(parents=True, exist_ok=True)
    logs = []
    result = {"evidence": "rtl_simulation_not_board_test", "passed": False,
              "utc": datetime.now(timezone.utc).isoformat(),
              "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
              "testbench_sha256": hashlib.sha256(testbench.read_bytes()).hexdigest(),
              "cases": [{"frames_per_packet": 17, "channels": 4, "packets": 3, "fifo_depth": 8},
                        {"frames_per_packet": 12208, "channels": 4, "packets": 2, "fifo_depth": 4096}]}
    try:
        with tempfile.TemporaryDirectory(prefix="xsim_", dir=work) as temporary:
            env = os.environ.copy()
            env.update(TEMP=temporary, TMP=temporary)
            commands = [[str(tools / "xvlog.bat"), "--sv", str(source), str(testbench), str(banner), str(banner_test)],
                        [str(tools / "xelab.bat"), "tb_packetizer", "-s", "packet_test"],
                        [str(tools / "xsim.bat"), "packet_test", "-runall"]]
            for command in commands:
                completed = subprocess.run(command, cwd=temporary, env=env, text=True,
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           errors="replace", timeout=240)
                logs.append("COMMAND: " + repr(command) + "\n" + completed.stdout)
                if completed.returncode:
                    raise RuntimeError("Vivado simulation command failed")
            if "PACKETIZER_REGRESSION_PASS" not in completed.stdout:
                raise RuntimeError("Simulation missing PASS marker")
            shutil.copyfile(Path(temporary) / "packetizer_trace.csv", output / "rtl_packetizer_trace.csv")
            result["packetizer_passed"] = True
            result["case_output"] = [line for line in completed.stdout.splitlines()
                                     if line.startswith("CASE_PASS")]
            for command in ([str(tools / "xelab.bat"), "tb_name_banner", "-s", "banner_test"],
                            [str(tools / "xsim.bat"), "banner_test", "-runall"]):
                completed = subprocess.run(command, cwd=temporary, env=env, text=True,
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           errors="replace", timeout=240)
                logs.append("COMMAND: " + repr(command) + "\n" + completed.stdout)
                if completed.returncode:
                    result["passed"] = False
                    raise RuntimeError("Banner simulation command failed")
            result["banner_passed"] = "NAME_BANNER_REGRESSION_PASS" in completed.stdout
            result["passed"] = result["banner_passed"]
            result["banner_source_sha256"] = hashlib.sha256(banner.read_bytes()).hexdigest()
            result["banner_test_sha256"] = hashlib.sha256(banner_test.read_bytes()).hexdigest()
            if not result["passed"]:
                raise RuntimeError("Missing banner PASS marker")
    finally:
        (output / "rtl_packetizer.log").write_text("\n".join(logs), encoding="utf-8")
        (output / "rtl_summary.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
