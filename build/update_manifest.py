"""Regenerate the release hash manifest without build caches or self-hashes."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def excluded(relative):
    parts = relative.parts
    if relative.as_posix() in ("release_manifest.json", "sim/results/release_check.json"):
        return True
    if any(part in {".git", "__pycache__", ".Xil", ".cache", ".wsdata"} for part in parts):
        return True
    if any(part.startswith(".venv") or part.endswith((".cache", ".runs", ".hw")) for part in parts):
        return True
    if relative.suffix in {".pyc", ".jou"}:
        return True
    if parts[:2] == ("build", "output"):
        return True
    if parts[:2] == ("src", "vitis") and any(part in {"build", "logs"} for part in parts[2:]):
        return True
    return False


def main():
    files = []
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        if excluded(relative):
            continue
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        files.append({"path": relative.as_posix(), "bytes": path.stat().st_size,
                      "sha256": digest.hexdigest()})
    manifest = {"project": "zhi_er_sound_assist",
                "updated_utc": datetime.now(timezone.utc).isoformat(),
                "source": "team source/artifacts plus reusable skill and independently executed regressions",
                "exclusions": ["self", "release_check.json", "build/output", "tool and Python caches"],
                "files": files}
    (ROOT / "release_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                                                encoding="utf-8")
    print(json.dumps({"manifest_files": len(files), "manifest_bytes": sum(item["bytes"] for item in files)}))


if __name__ == "__main__":
    main()
