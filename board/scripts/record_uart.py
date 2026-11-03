"""Read real UART bytes plus demultiplexed text/packet metadata; no simulated board data."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src/web"))
from protocol import Parser


class Lines:
    def __init__(self, publish):
        self.pending = bytearray()
        self.publish = publish

    def feed(self, data):
        for value in data:
            if value == 10:
                text = self.pending.decode("ascii").strip()
                self.pending.clear()
                if text:
                    event = {"type": "text", "text": text}
                    if text.startswith("Sound: "):
                        event.update(type="recognition", label=text[7:])
                    elif text.startswith("NameAlert:"):
                        event["type"] = "name_alert"
                    elif text.startswith(("CAPTURE FAILED", "DMA ERROR", "WRONG HARDWARE")):
                        event["type"] = "board_error"
                    self.publish(event)
            elif value in (9, 13) or 32 <= value < 127:
                if len(self.pending) >= 4096:
                    self.pending.clear()
                self.pending.append(value)
            else:
                self.pending.clear()


def file_sha(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--seconds", type=float, default=120)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or args.seconds <= 0 or args.baud <= 0:
        raise ValueError("Positive baud/duration required")
    import serial
    if args.output.exists() and any(args.output.iterdir()):
        raise FileExistsError("Use a new recording directory")
    # Open before creating outputs: an unavailable port must not create a fake recording.
    connection = serial.Serial(args.port, args.baud, timeout=0.1)
    args.output.mkdir(parents=True, exist_ok=True)
    start = time.perf_counter()
    packet_count = byte_count = event_count = 0
    report = {"evidence": "real_serial_capture", "port": args.port, "baud": args.baud,
              "started_utc": datetime.now(timezone.utc).isoformat(), "completed": False,
              "timestamps": "host_receive_time_not_board_inference_latency",
              "capture_scope": "UART multiplexed text and CH0 display PCM; not model input"}
    try:
        with (args.output / "uart.bin").open("xb") as raw, (args.output / "events.jsonl").open(
                "x", encoding="utf-8") as events, (args.output / "packets.jsonl").open("x", encoding="utf-8") as packets:
            def publish(event):
                nonlocal event_count
                event["host_elapsed_s"] = time.perf_counter() - start
                events.write(json.dumps(event, ensure_ascii=False) + "\n")
                events.flush()
                event_count += 1
                print(json.dumps(event, ensure_ascii=True))
            stream = Parser(Lines(publish).feed)
            try:
                while time.perf_counter() - start < args.seconds:
                    data = connection.read(min(max(connection.in_waiting, 1), 16384))
                    if not data:
                        continue
                    raw.write(data)
                    byte_count += len(data)
                    for packet in stream.feed(data):
                        packet_count += 1
                        entry = {"host_elapsed_s": time.perf_counter() - start,
                                 "sequence": int(packet["sequence"]),
                                 "rate_hz": packet["rate"], "flags": packet["flags"],
                                 "channels": packet["channels"],
                                 "shape": list(packet["samples"].shape),
                                 "pcm_sha256": hashlib.sha256(packet["samples"].tobytes()).hexdigest()}
                        packets.write(json.dumps(entry) + "\n")
                report["completed"] = True
            except KeyboardInterrupt:
                report["interrupted_by_user"] = True
            finally:
                report["crc_errors"] = stream.crc_errors
    except Exception as error:
        report["error"] = repr(error)
        raise
    finally:
        connection.close()
        report.update(elapsed_s=time.perf_counter() - start, uart_bytes=byte_count,
                      packet_count=packet_count, event_count=event_count)
        report["local_artifact_sha256"] = {path.name: file_sha(path) for path in
            sorted((ROOT / "board/artifacts").iterdir()) if path.is_file()}
        report["recorded_file_sha256"] = {path.name: file_sha(path) for path in args.output.iterdir()
                                          if path.is_file() and path.name != "summary.json"}
        (args.output / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
