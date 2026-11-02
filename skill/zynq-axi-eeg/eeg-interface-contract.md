# EEG processing interface contract

Use this reference only for the PYNQ-Z2 EEG project represented by the supplied `eeg_filter_top`, `eeg_spatial_filter_3tgt`, and PS Python sources. Confirm these conventions against the active RTL and Block Design before reuse.

## Clock domains

| Domain | Nominal clock | Use |
|---|---:|---|
| AXI and EEG processing | 125 MHz | DMA, IIR, spatial projection, AXI-Lite |
| HDMI pixel | 148.5 MHz | 1920×1080 at 60 Hz stimulus generation |
| EEG sampling | 500 Hz | External acquisition time base |

Any signal crossing between the 125 MHz and 148.5 MHz domains needs an explicit CDC mechanism. Continuous sample data must not cross as unrelated individual bits.

## Stream contract

| Field | Input to processing chain | Output from spatial filter |
|---|---|---|
| Width | `TDATA[31:0]` | `TDATA[31:0]` |
| Type | signed Q24 `int32` after PS preparation | signed Q24 `int32` after accumulator rounding/right shift |
| Ordering | time-major: `t0:[ch1..ch7], t1:[ch1..ch7], ...` | time-major: `t0:[z1,z2,z3], t1:[z1,z2,z3], ...` |
| Group size | 7 stream beats per EEG sample time | 3 stream beats per EEG sample time |
| Packet end | End of the DMA transfer, unless the active RTL explicitly regenerates a group-level marker | End of the corresponding DMA transfer |

The current PS code allocates the common online window as `cca_len = 1000` and uses `dma_in.shape = 1000 × 7`, `dma_out.shape = 1000 × 3`. The 1000 points correspond to a 2 s window at 500 Hz.

## Fixed-point convention

PS subtracts each analysis channel's mean, normalizes by the maximum absolute amplitude of the full window, then converts with `round(x × 2^24)` to signed `int32`. RTL coefficient and data arithmetic use Q24 scaling; multiplication accumulates in signed 64-bit state and returns `round(accumulator / 2^24)`. Preserve signed interpretation through DMA buffer views and MMIO writes.

## Spatial filter register map

The three target vectors comprise 21 signed Q24 coefficients. Current PS code uses:

| Target | Base offset | Channels |
|---|---:|---|
| target 1 | `0x00` | `0x00` through `0x18`, 4-byte stride |
| target 2 | `0x1C` | `0x1C` through `0x34`, 4-byte stride |
| target 3 | `0x38` | `0x38` through `0x50`, 4-byte stride |

For a negative Q24 coefficient, PS writes the unsigned 32-bit two's-complement representation. A robust AXI-Lite slave must accept independent address/data handshakes, hold responses until accepted, and define the active-update behavior when host writes occur during streaming.

## PYNQ DMA sequence

1. Allocate physically contiguous buffers with dtype `np.int32`.
2. Populate the input buffer in the declared time-major order.
3. Start `recvchannel.transfer(dma_out)` before `sendchannel.transfer(dma_in)`.
4. Wait for send and receive completion.
5. Reshape the output as `(-1, 3).T` only after receive completion.

## Known engineering evidence

The available routed report for this project lists total resources of 4,909 LUTs, 7,082 registers, 2 BRAM tiles, and 28 DSP48E1 blocks. It also reports WNS −6.529 ns and TNS −2883.098 ns. The design can produce a bitstream while still failing timing; treat timing closure as an open requirement until a re-run has no relevant violations.
