"""Compare traceable manual board observations; not a statistical accuracy test."""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def compare(path):
    with path.open(encoding="utf-8-sig", newline="") as source:
        records = list(csv.DictReader(source))
    if not records:
        raise ValueError("No observations")
    identifiers = set()
    evidence_hashes = {}
    for row in records:
        for key in ("case_id", "function", "reference", "observed", "evidence", "reference_source",
                    "basis", "notes"):
            if not row.get(key, "").strip():
                raise ValueError("Missing observation field " + key)
        if row["case_id"] in identifiers:
            raise ValueError("Duplicate case identifier")
        identifiers.add(row["case_id"])
        start, end = float(row["start_s"]), float(row["end_s"])
        if not 0 <= start <= end < float("inf"):
            raise ValueError("Invalid evidence time")
        if row["basis"] != "video_manual_observation":
            raise ValueError("This table is for manual video observations only")
        for key in ("evidence", "reference_source"):
            target = (ROOT / row[key]).resolve()
            if not target.is_relative_to(ROOT.resolve()) or not target.is_file():
                raise ValueError("Missing/unsafe evidence: " + row[key])
            if row[key] not in evidence_hashes:
                evidence_hashes[row[key]] = digest(target)
        row["comparison"] = "observed_match" if row["reference"] == row["observed"] else "observed_mismatch"
    return {"evidence_level": "manual_video_comparison", "created_utc": datetime.now(timezone.utc).isoformat(),
            "source_csv_sha256": digest(path), "records": records, "record_count": len(records),
            "matching_observations": sum(row["comparison"] == "observed_match" for row in records),
            "statistical_accuracy_computed": False, "paired_board_pcm_available": False,
            "complete_uart_log_available": False, "evidence_sha256": evidence_hashes,
            "local_artifact_sha256": {path.name: digest(path) for path in sorted(
                (ROOT / "board/artifacts").iterdir()) if path.is_file()},
            "limitations": ["Manual transcription from existing video/subtitles, not independent sensor ground truth",
                            "No statistical accuracy, false-positive rate, latency or continuous-stream proof",
                            "Local artifact hashes do not attest the firmware identity in the recorded video"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, default=ROOT / "board/validation/video_comparison.csv")
    parser.add_argument("--output", type=Path, default=ROOT / "board/validation")
    args = parser.parse_args()
    result = compare(args.csv)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "comparison_summary.json").write_text(
        json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    lines = ["# 实测输出与参考行为对照", "",
             "依据团队原始实物视频人工整理，不是统计准确率或逐样本板端黄金参考。", "",
             "| 编号 | 功能 | 时间（秒） | 参考行为 | 观察输出 | 对照 |", "|---|---|---|---|---|---|"]
    for row in result["records"]:
        lines.append("| " + " | ".join([row["case_id"], row["function"],
            row["start_s"] + "-" + row["end_s"], row["reference"], row["observed"], row["comparison"]]) + " |")
    lines += ["", "证据文件、观察方法、逐项限制与SHA-256见 comparison_summary.json；解释边界见 README.md。",
              "未提供完整UART、16kHz模型输入配对数据；不得据此填报100%准确率、零误报或实测延迟。", ""]
    (args.output / "comparison_report.md").write_text("\n".join(lines), encoding="utf-8")
    print(json.dumps({"records": result["record_count"],
                      "matching_observations": result["matching_observations"],
                      "evidence": result["evidence_level"], "statistical_accuracy_computed": False}))
    return int(any(row["comparison"] != "observed_match" for row in result["records"]))


if __name__ == "__main__":
    raise SystemExit(main())
