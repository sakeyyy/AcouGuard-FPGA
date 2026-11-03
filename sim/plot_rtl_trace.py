"""Plot only the CSV exported by the executed RTL testbench."""
import csv
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "sim/results"


def main():
    with (OUTPUT / "rtl_packetizer_trace.csv").open(encoding="utf-8") as source:
        records = list(csv.DictReader(source))
    records = [row for row in records if 250 <= int(row["cycle"]) <= 360]
    clocks = np.array([int(row["cycle"]) for row in records])
    fig, axes = plt.subplots(6, 1, figsize=(13, 8), sharex=True,
                             gridspec_kw={"height_ratios": [1, 1, 1, 1.5, 1, 1]})
    for axis, key in zip(axes, ("valid", "ready", "handshake", "data_hex", "last", "done")):
        if key == "data_hex":
            words = np.array([int(row[key], 16) for row in records], dtype=np.uint32).view(np.int32)
            visible = np.array([row["valid"] == "1" for row in records])
            axis.step(clocks, np.where(visible, words, np.nan), where="post", color="#006d77")
            axis.set_ylim(-100, 100)
            axis.set_ylabel("PCM int32")
            axis.text(.01, .82, "Display clipped to +/-100; boundary values tested numerically",
                      transform=axis.transAxes, fontsize=8)
        else:
            values = ([int(row["valid"] == "1" and row["ready"] == "1") for row in records]
                      if key == "handshake" else [int(row[key]) for row in records])
            axis.step(clocks, values, where="post", color="#263238")
            axis.set_yticks([0, 1])
            axis.set_ylim(-.2, 1.3)
            axis.set_ylabel(key)
        axis.grid(alpha=.2)
    axes[-1].set_xlabel("50 MHz clock cycle (testbench)")
    fig.suptitle("Executed RTL simulation: channel interleaving, backpressure and packet boundary\n"
                 "Small case: 17 frames x 4 channels per packet; not a physical-board waveform",
                 fontsize=12)
    fig.tight_layout(rect=(0, 0, 1, .93))
    fig.savefig(OUTPUT / "rtl_packetizer_waveform.png", dpi=160)
    plt.close(fig)
    print(json.dumps({"source": "rtl_packetizer_trace.csv",
                      "figure": "rtl_packetizer_waveform.png", "evidence": "executed_rtl_trace"}))


if __name__ == "__main__":
    main()
