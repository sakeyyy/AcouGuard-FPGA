"""Create a cache-free ZIP from the already checked release manifest."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    target = args.output.resolve()
    if target.is_relative_to(ROOT.resolve()):
        raise ValueError("Write the ZIP outside the project to avoid including itself")
    if target.exists():
        raise FileExistsError("Choose a new filename; will not overwrite an existing archive")
    subprocess.run([sys.executable, str(ROOT / "sim/check_package.py"),
                    "--output", "sim/results/release_check.json"], cwd=ROOT, check=True)
    manifest = json.loads((ROOT / "release_manifest.json").read_text(encoding="utf-8"))
    paths = [ROOT / record["path"] for record in manifest["files"]]
    paths += [ROOT / "release_manifest.json", ROOT / "sim/results/release_check.json"]
    with zipfile.ZipFile(target, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in paths:
            archive.write(path, ROOT.name + "/" + path.relative_to(ROOT).as_posix())
    with zipfile.ZipFile(target) as archive:
        invalid = archive.testzip()
        if invalid:
            raise RuntimeError("ZIP CRC verification failed: " + invalid)
    digest = hashlib.sha256()
    with target.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    print(json.dumps({"archive": str(target), "files": len(paths), "bytes": target.stat().st_size,
                      "sha256": digest.hexdigest(), "zip_crc_checked": True}))


if __name__ == "__main__":
    main()
