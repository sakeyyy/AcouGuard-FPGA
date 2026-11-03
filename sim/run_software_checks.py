"""Capture current software checks and metadata inspection without changing artifacts."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "skill/pynq-stream-validation"
sys.path.insert(0, str(SKILL / "scripts"))
import stream_skill


def main():
    commands = [
        [sys.executable, "sim/test_web_protocol.py"],
        [sys.executable, "build/export_model.py", "--output", "build/output/unused", "--verify-only"],
        [sys.executable, "build/rebuild_vitis.py", "--check-only"],
        [sys.executable, str(SKILL / "scripts/stream_skill.py"), "contract",
         str(SKILL / "examples/project_audio.json")]]
    result = {"utc": datetime.now(timezone.utc).isoformat(), "hardware_tested": False,
              "evidence": "software_checks", "commands": [], "passed": False}
    output = ROOT / "sim/results/current_software_checks.json"
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    try:
        for command in commands:
            completed = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                       text=True, errors="replace", timeout=180)
            result["commands"].append({"command": command, "returncode": completed.returncode,
                                       "stdout": completed.stdout, "stderr": completed.stderr})
            if completed.returncode:
                raise RuntimeError("Software check failed: " + repr(command))
        with zipfile.ZipFile(ROOT / "board/artifacts/audio_platform.xsa") as archive:
            names = [name for name in archive.namelist() if name.endswith(".hwh")]
            result["xsa_hwh_members"] = names
            candidates = []
            for name in names:
                raw = archive.read(name)
                if any(":axi_dma:" in module.get("VLNV", "")
                       for module in ET.fromstring(raw).iter("MODULE")):
                    candidates.append((name, raw))
            result["dma_hwh_members"] = [name for name, _ in candidates]
            if len(candidates) == 1:
                _, xml = candidates[0]
                dma_modules = []
                for module in ET.fromstring(xml).iter("MODULE"):
                    if ":axi_dma:" in module.get("VLNV", ""):
                        params = {item.get("NAME"): item.get("VALUE") for item in module.iter("PARAMETER")}
                        dma_modules.append({"name": module.get("FULLNAME", module.get("INSTANCE")),
                                            "vlnv": module.get("VLNV"),
                                            "parameters": {key: value for key, value in params.items()
                                                           if key in ("C_INCLUDE_SG", "C_SG_LENGTH_WIDTH",
                                                                      "C_S_AXIS_S2MM_TDATA_WIDTH",
                                                                      "C_INCLUDE_S2MM")}})
                result["actual_hwh_dma_metadata"] = dma_modules
                if len(dma_modules) == 1:
                    contract = stream_skill.load_contract(SKILL / "examples/project_audio.json")
                    with tempfile.TemporaryDirectory(dir=ROOT / "build/output", prefix="hwh_check_") as temporary:
                        directory = Path(temporary)
                        contract["_directory"] = str(directory)
                        contract["dma_ip"] = dma_modules[0]["name"].strip("/")
                        (directory / contract["hwh"]).write_bytes(xml)
                        with archive.open(next(name for name in archive.namelist() if name.endswith(".bit"))) as source:
                            (directory / contract["bitfile"]).write_bytes(source.read())
                        result["actual_xsa_pair_preflight"] = stream_skill.preflight(contract)
        result["passed"] = True
    finally:
        output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, ensure_ascii=True))


if __name__ == "__main__":
    main()
