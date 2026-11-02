---
name: zynq-axi-eeg
description: "Design, integrate, review, or debug AXI4-Lite, AXI-Stream, and AXI DMA data paths on Zynq or PYNQ, especially for fixed-point EEG processing RTL. Use for custom AXI IP, PS-PL buffer contracts, register maps, handshake failures, or Vivado timing/ILA validation."
---

# Zynq AXI EEG

Use this skill for Zynq/PYNQ designs where a PS program configures or streams data through custom PL RTL. It focuses on the interface contract and verification of AXI4-Lite, AXI-Stream, and AXI DMA. Do not use it for non-AXI peripheral design unless the request includes an AXI integration boundary.

## Choose the interface before changing RTL

- Use **AXI4-Lite** for infrequent scalar control: register configuration, status, interrupts, and coefficient updates.
- Use **AXI-Stream** for continuous samples with a defined ordering and packet boundary.
- Use **AXI DMA** only when PS DDR buffers must exchange a stream with PL. State the buffer shape, dtype, unit, and sample ordering on both sides.

For this project family, start with the local defaults in [the EEG interface contract](references/eeg-interface-contract.md). Treat them as project conventions, not universal AXI requirements. If a request gives different dimensions, clocks, fixed-point formats, or packetization, use the request and update the stated contract before code changes.

## Required design contract

Before writing or reviewing code, identify these items in the answer or implementation plan:

1. Clock and reset domain for every AXI interface, including reset polarity and synchronization method.
2. AXI role and width: master/slave; Lite or Stream; `TDATA` width; and any `TKEEP`, `TLAST`, `TUSER`, or sideband semantics.
3. Data representation: signedness, fixed-point scaling, saturation/rounding choice, and expected buffer layout.
4. Packet rule: what begins and ends a transaction or frame, exactly when `TLAST` asserts, and whether it represents a sample group or the whole DMA transfer.
5. Register map for AXI4-Lite: byte offsets, reset values, read/write policy, and the software value-to-register conversion.
6. Backpressure policy: where data can stall, buffer depth, and what remains stable during the stall.
7. Verification target: testbench checks, ILA observability, and timing/CDC acceptance criteria.

Do not infer a register address, scale factor, channel order, or DMA output size from a similar module. Flag it as an assumption when the project does not define it.

## AXI correctness rules

### AXI4-Lite

- `AW` and `W` channels are independent. A compliant slave must accept address and write data in either order; do not require both to arrive in one cycle.
- After asserting `BVALID` or `RVALID`, hold it and its response/data stable until the corresponding `BREADY` or `RREADY` handshake.
- Apply `WSTRB` when partial writes are supported. If partial writes are intentionally unsupported, document that restriction and reject or mask them deterministically.
- Decode aligned byte offsets and reserve undefined offsets. Return a defined response for invalid accesses.
- Do not expose a configuration that can change a multiword coefficient set mid-frame unless the interface provides an explicit commit/active-bank rule.

### AXI-Stream

- Transfer occurs only when `TVALID && TREADY` is true. The producer holds `TDATA`, `TLAST`, and all asserted sidebands stable while `TVALID=1` and `TREADY=0`.
- Advance channel counters, state machines, accumulators, and output indices only on a completed handshake.
- Do not derive a combinational path that can create a `TVALID`/`TREADY` loop across modules. Add an elastic register, FIFO, or clear registered boundary when needed.
- Preserve `TLAST` according to the declared packet rule. Do not repurpose it as an internal channel marker without documenting the conversion.

### DMA and clocking

- Program receiver DMA before transmitter DMA when the PL kernel can emit output immediately; wait for both channels before consuming output.
- Check DMA buffer length against the RTL packet rule. A mismatch can look like a deadlock, dropped samples, or a misplaced `TLAST`.
- Cross AXI/processing and HDMI/pixel clocks only through a synchronizer for single-bit controls, or an asynchronous FIFO/AXI Clock Converter for data streams. A two-flop synchronizer does not preserve multi-bit sample coherence.
- Treat a generated bitstream as non-final when the implementation report has setup, hold, or pulse-width violations. Report WNS/TNS and the failing-clock relationship instead of claiming hardware timing closure.

## Implementation and review workflow

1. Read the existing Block Design, custom RTL ports, PYNQ/PS calls, and constraints before changing a boundary.
2. Write a compact interface table covering clock, interface, width, data order, and packet boundary.
3. Check register behavior or stream handshakes in a focused testbench. Exercise backpressure and reset during idle and active traffic.
4. For a DMA path, confirm one known input buffer yields the expected output order and number of samples before benchmarking.
5. Use ILA or signal probes to inspect `TVALID`, `TREADY`, `TLAST`, reset, and key state counters only when simulation or software logs do not isolate the failure.
6. Check CDC and routed timing after structural changes. Do not treat successful bitstream generation as proof of timing closure.

When reviewing existing code, distinguish a documented project limitation from an AXI protocol defect. Provide the smallest safe correction and state whether it changes software, RTL, or both.

## Expected deliverables

For design work, return the interface table, register map or stream layout, modified RTL/PS code, and a verification plan. For debugging, report the observed handshake or timing evidence, root cause, exact correction, and retest criteria. Do not launch synthesis, write bitstreams, or modify hardware projects unless the user asks for that action.
