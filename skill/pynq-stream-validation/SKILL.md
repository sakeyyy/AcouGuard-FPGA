---
name: pynq-stream-validation
description: Validate fixed-length AXI DMA stream contracts, generate PYNQ host skeletons, diagnose transfers, compare golden arrays and extract Vivado metrics. Use for Overlay verification, not SG DMA or audio classifier design.
---

# PYNQ Stream Validation

Read README.md for commands/schema. Establish frames, channel order, dtype, signed payload bits, stream width, TLAST and length width before coding. Validate contracts with scripts/stream_skill.py; discover DMA from HWH, never copy an address. BIT/HWH must come from the same export.

Generate a host skeleton. Acquisition needs real start/stop callbacks: arming DMA does not start the sensor. Receive before transmit, flush/invalidate, check exact bytes. Stop safely on errors, never free active DMA buffers. Compare to an independent golden reference; preserve report hashes and constraint warnings.

Label evidence as software mock, RTL simulation, historical report or physical test. A mock cannot prove Overlay loading, cache coherence, speedup or portability. Keep the main application distinct from this companion runtime: ELF/NPZ is not an Overlay.

Read references/troubleshooting.md for symptoms, references/prompts.md for LLM workflows, references/validation.md before hardware claims.

Read references/competition_mapping.md for competition examples, cross-domain reuse and board migration. scripts/measurement.py adds read-only register_map field inspection and repeated host-side DMA measurements; never report host-call timing as isolated kernel latency.
