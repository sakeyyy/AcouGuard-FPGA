# PYNQ Stream Validation Toolkit

Copy this folder to another project. Offline tools require Python 3.10+ and NumPy. PYNQ imports are lazy. No task-specific pins, labels or addresses are embedded.

## Commands

From this folder:

~~~text
python scripts/stream_skill.py contract examples/loopback.json
python scripts/stream_skill.py preflight my_contract.json
python scripts/stream_skill.py generate my_contract.json --output generated
python scripts/stream_skill.py compare golden.npy received.npy --atol 0.00001 --rtol 0.00001
python scripts/stream_skill.py reports --utilization utilization.rpt --timing timing_summary.rpt --output metrics.json
python tests/test_stream_skill.py --output test_results.json
python tests/test_measurement.py --output measurement_tests.json
~~~

Generation refuses a nonempty directory, copies runtime/contract/runner/reference test. Provide matching BIT/HWH next to generated contract, then run python run.py --input input.npy on PYNQ for loopback, or python run.py for externally triggered capture. Output: received.npy. Test fixtures are not downloadable overlays.

## Schema 1

The generator also writes validate.ipynb with empty outputs: open it on the PYNQ Jupyter server after adapting acquisition callbacks. It is an unexecuted template, not a recorded board success.

Required: schema_version, name, mode (receive/loopback), dtype, valid_bits, channels, channel_order, frames, stream_width_bits, dma_length_width, dma_alignment, bitfile, hwh, dma_ip. Optional: signed_pcm, sample_rate_hz, register_checks entries {ip, offset, mask, expected}. See examples.

Buffers are (frames, channels) C-order. Bytes = frames * channels * dtype.itemsize, within 2**dma_length_width-1. Whole stream beats/full TKEEP only, TLAST per packet. valid_bits is right-aligned payload without shifting/normalization; signed_pcm validates sign extension on comparison. Physical channel semantics require independent stimulation.

Stream width: power-of-two 8..512. dma_alignment follows DMA memory-map width/DRE, conservatively 64 in examples. HWH C_SG_LENGTH_WIDTH must match, C_INCLUDE_SG must be zero. Paths relative to contract. Register numeric fields support decimal/hex strings; use only side-effect-free read-only signature registers.

## Notebook API

~~~python
from scripts.stream_skill import load_contract, open_overlay, receive_once
contract = load_contract("my_contract.json")
overlay, dma = open_overlay(contract)
print(dma.register_map)

def start_capture():
    overlay.capture_control.write(0, 1)

def stop_capture():
    overlay.capture_control.write(0, 0)

samples = receive_once(dma, contract, timeout_s=2.0,
                       start=start_capture, stop=stop_capture)
~~~

capture_control is illustrative: replace its instance/register with the actual design. Hierarchical DMA names supported. One packet only: continuous lossless capture needs a separate ping-pong scheduler.

On error stop channels and wait for Halted before freeing. If stopping fails, buffers stay in QUARANTINED_BUFFERS and hardware must be reloaded; do not manually free while DMA can still access them. Physical driver/cache behavior requires hardware tests.

## Comparison and Reports

compare rejects differing shape/dtype and NaN/Inf; integer exact, float explicit tolerance, nonzero exit on mismatch. --contract checks layout/PCM range. NPY loads disable pickle. Output includes hashes and mismatch count.

reports requires resource rows and numeric timing, preserves missing-delay warnings and hashes. --baseline baseline_metrics.json emits deltas, not an assertion of comparable conditions or speedup. No inferred board latency/power. Unknown formats fail.

See references/validation.md for physical acceptance; parent README documents applicability, usage, failure conditions, verified effects and provenance for every item.

## Independent Reuse Catalog

Detailed competition mapping and five other application domains are documented in references/competition_mapping.md, including board migration and unsupported interface changes.

## Register Map and Performance Commands

On an actual PYNQ board with a valid contract:

~~~text
python scripts/measurement.py registers my_contract.json --ip axi_dma_0 --field S2MM_DMASR.Halted --field S2MM_DMASR.Idle --output registers.json
python scripts/measurement.py benchmark my_contract.json --input input.npy --golden golden.npy --iterations 20 --warmup 3 --output performance.json
~~~

Register/field names above follow a typical AXI DMA driver; inspect your own register_map first because names may differ. Reads must be side-effect-free. This command performs no register writes. Signature checks can also be supplied as explicit masked offset reads in contract.register_checks.

Benchmark CLI requires a same-shape loopback contract; receive-only capture uses the benchmark API with a callable that passes real start/stop callbacks to receive_once. It emits JSON/Markdown, per-iteration duration/hash, optional golden comparison, median/p95 and effective payload throughput. Errors yield a failed report/nonzero exit. Time is host DMA helper time, including allocation/cache/trigger/copy, not FPGA kernel cycles, acoustic recognition latency or sustainable continuous-stream bandwidth.

To produce a complete resource/performance submission, run stream_skill.py reports on the same build's Vivado reports and keep its hashed resource JSON beside performance.json. A baseline must be measured under the same conditions; neither script invents a baseline.

Receive-only Notebook/API example (provide real trigger callbacks as in the earlier API example):

~~~python
from scripts.measurement import benchmark, save_report
result = benchmark(
    lambda: receive_once(dma, contract, start=start_capture, stop=stop_capture),
    iterations=20, warmup=3, contract=contract)
save_report("capture_performance.json", result)
assert result["passed"]
~~~

Without a golden array this validates transfer completion/layout but not numerical algorithm correctness. Benchmark's optional golden comparison is exact by default; use compare separately with an explicit tolerance for algorithms that require floating-point tolerance.

## Reuse Conditions

| Item | Applicability | Usage | Failure conditions | Verified effects | Failure/observation source |
|---|---|---|---|---|---|
| Contract/Overlay/generator | Fixed packets, one simple AXI DMA | contract, preflight, generate; replace JSON IP/layout | SG/variable packets/partial beats, missing HWH parameters, wrong export pair | Offline tests: generic layouts, synthetic HWH, rejection and skeleton syntax | Four-channel migration, mismatched packet length; injected HWH faults |
| DMA/cache | allocate, receive or loopback | receive_once, RX before TX/arm, flush/invalidate | TLAST/reset/clock/alignment errors; nonhalting DMA retains buffers; continuous streams need scheduler | Mock verifies ordering, short/error/timeout/cleanup, not physical cache/speed | First-packet-only, old module binding, reset and overflow observations |
| Golden/reports | NPY; Vivado utilization/timing | compare; reports with optional real baseline | Shape/type/nonfinite data, unsupported reports, incomparable baselines | Exact integer/float tolerance/rejections; warnings preserved | PC/PS differences, positive WNS with missing I/O delay |
| Prompts/troubleshooting | Evidence-driven LLM work | Fill prompts.md, run checks, save corrections | Missing evidence yields hypotheses; no guaranteed model success | Executable engineering checks, no cross-model success statistics | Pin semantics, channel upgrades, stale reports, model-vs-Overlay confusion |

Test outputs are software evidence. The board-only checklist and evidence boundaries are in references/validation.md.
