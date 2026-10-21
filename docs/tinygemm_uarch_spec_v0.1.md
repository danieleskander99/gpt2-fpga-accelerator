# TinyGEMM — INT8 Systolic Matrix-Multiply Accelerator

**Micro-architecture Specification v0.2** — 21 Oct 2026 — personal project, in progress

---

## 1. Purpose and scope

TinyGEMM computes `C = A × B` for INT8 matrices A (M×K) and B (K×N), producing INT32 results. It uses an 8×8 weight-stationary systolic array fed from double-buffered on-chip tile buffers by an autonomous AXI4 DMA engine. The design goal is **sustained array utilisation** rather than peak throughput: the memory subsystem has to keep the array busy across tile boundaries, and hardware counters measure how well it does.

The accelerator runs on a Kintex-7 FPGA board. Matrices live in the board's DDR3, and a host PC loads data, launches jobs and reads results over PCIe.

Out of scope for v1: bias and activation functions, non-INT8 data types, sparsity, and multi-array scaling. These are listed as future work in §12.

## 2. Target platform

| Item | Value | Source |
|---|---|---|
| FPGA | AMD/Xilinx Kintex-7 **XC7K325T-2FFG676C** | board schematic |
| Logic cells | 326,080 | DS180 |
| DSP slices | **840** DSP48E1 (25×18 multiplier, 48-bit accumulator, pre-adder) | DS180 |
| Block RAM | 445 × 36 Kb = 16,020 Kb (~2 MB) | DS180 |
| External memory | **1 GB DDR3**: 2 × Micron MT41K256M16 (DDR3L parts run at 1.5 V), 32-bit data bus | schematic |
| Memory bandwidth | 6.4 GB/s peak at DDR3-1600; ~5 GB/s assumed usable | §5.4 |
| Host link | **PCIe Gen2 x4** (~2 GB/s per direction) via the XDMA IP | board constraints |
| Toolchain | Vivado (scripted Tcl flow); Vivado Simulator (XSim) with UVM 1.2 for verification | |

The 8×8 array uses 64 of the 840 DSP slices (7.6%). The RTL is parameterised so larger arrays (16×16 = 256 DSPs, up to ~28×28 = 784 DSPs) build from the same source; `performance_model.md` explains when a larger array pays off and when memory bandwidth makes it pointless.

## 3. Top-level block diagram

```
                 axi_clk domain                     |           core_clk domain
                                                    |
  AXI4-Lite ──► [CSR block] ──► CDC (req/ack) ─────┼──► [Scheduler / Tile FSM]
  (host via PCIe)    ▲                              |            │
                     │ status/counters (CDC) ◄──────┼────────────┤
                                                    |            ▼
  AXI4 master ◄──► [DMA engine] ◄───────────────────┼──── tile load/store requests
  (DDR3 via MIG)       │  │                         |
                       │  └──► [A tile buf 0/1] ──► [Skew] ──► [8×8 PE array] ──► [Deskew] ──► [C tile buf] ──┐
                       └─────► [B tile buf 0/1] ──► weight load ───┘                                          │
                                                    ▲                                                          │
                                                    └──────────────────────── DMA write-back ◄────────────────┘
```

The full end-to-end flow of one job is shown in `tinygemm_system_journey.svg`.

**Board integration.** The core (`rtl/`) contains no vendor IP. The board top level (`fpga/board_top.sv`) instantiates it alongside the Xilinx MIG DDR3 controller, the XDMA PCIe IP and the clocking wizard. The host reaches the CSR block through the XDMA's AXI4-Lite port and reaches DDR through the XDMA's AXI4 master, so the PC can write A and B into DDR, start a job and read C back.

**Clocks.** `axi_clk` drives the DMA, the CSR block and the interconnect towards the MIG and XDMA. `core_clk` drives the scheduler, the array and the read side of the tile buffers, with a 200 MHz target. The tile buffers are dual-clock (written on `axi_clk`, read on `core_clk`), so the clock-domain crossing for data is contained inside the buffers plus a small control handshake. This is the only deliberate CDC in the design.

## 4. Numerics

| Item | Choice | Rationale |
|---|---|---|
| Input A, B | INT8 signed | Standard inference format |
| Product | INT16 | 8×8 signed multiply |
| Accumulator | INT32 | Cannot overflow for K ≤ 2^16 (each product ≤ 2^14 in magnitude) |
| Output C | INT32, written as-is | Rescaling/requantisation is a v2 block |

Saturation is not implemented. K is limited to 4096 by the CSR block, which is well inside the overflow-free bound.

## 5. Systolic array

**Dataflow:** weight-stationary. Each processing element (PE) holds one element of the current 8×8 B tile: PE(k,n) holds b[k][n]. Rows of A stream left to right; partial sums flow top to bottom.

**PE (per cycle):**
```
a_out    <= a_in                        // pass A rightward (reuse)
psum_out <= psum_in + a_in * w_reg      // accumulate downward
```
Each PE maps onto one DSP48E1 slice (multiply plus add). Weights shift in vertically over 8 cycles during a load phase and then latch. A shadow weight register lets the weights for tile *t+1* load while tile *t* computes, so there is no bubble at tile boundaries.

**Skew / deskew:** input row *i* is delayed *i* cycles; output column *j* is realigned by 7−*j* cycles. Both are small shift registers (~64 bytes each).

**Latency per 8×8 tile:** 8 (weight load, hidden by the shadow register) + 8 (stream) + 7 (skew) + 8 (drain) cycles. In steady state the array accepts 8 A rows per 8 cycles, i.e. 64 MAC/cycle, which is 100% utilisation whenever the buffers are ready. At 200 MHz that is **12.8 GMAC/s (25.6 GOPS)** peak.

**Accumulation across K:** for K > 8, partial C tiles accumulate in the C buffer with a read-modify-write at the deskew output. The C buffer holds an 8×8 INT32 tile.

## 6. Memory subsystem

### 6.1 Tile buffers

| Buffer | Count | Size | Width | Ports |
|---|---|---|---|---|
| A tile | 2 (ping/pong) | 8 rows × 8 INT8, depth 64 | 64-bit (one row) | W: axi_clk, R: core_clk |
| B tile | 2 (ping/pong) | 8×8 INT8 | 64-bit | W: axi_clk, R: core_clk |
| C tile | 1 (a second is optional, to overlap write-back) | 8×8 INT32 | 256-bit | R/W: core_clk, R: axi_clk |

All buffers sit behind a `tile_ram.sv` wrapper. Its behavioural implementation infers block RAM in Vivado and simulates in any tool; an XPM-macro implementation is available behind a parameter if inference is not sufficient.

### 6.2 Tile schedule

For each output tile (mi, nj), the scheduler iterates over kk = 0 … K/8−1: load A(mi,kk) and B(kk,nj), compute, accumulate. Because B is stationary in the array, the baseline loop order is **N-outer, M-middle, K-inner**, so B tiles change only when nj changes. M-outer ordering (which favours A reuse instead) is the alternative; the trade-off is quantified in `loop_order_and_cbuf.md`.

Each buffer pair is managed by a 4-state FSM: IDLE → LOADING → READY → CONSUMING. The DMA fills the inactive buffer while the array consumes the active one. A **bubble** occurs when a tile's load time exceeds its compute time; a CSR counter records every bubble cycle.

### 6.3 DMA engine (AXI4 master)

- **Reads:** 64-bit data bus, INCR bursts of up to 16 beats. The address generator walks row-major matrices with an arbitrary leading dimension (`lda`, `ldb`, `ldc` CSRs), so ragged edges and strided sub-matrices are supported.
- **Writes:** C tile write-back, one 256-bit row as 4 beats of 64 bits.
- **Outstanding transactions:** 1 read + 1 write in v1. A second outstanding read is a parameterised optimisation.
- **Edge tiles:** M, N and K that are not multiples of 8 are zero-padded on load and masked on write-back.
- **DDR side:** an AXI interconnect in `fpga/` converts between the DMA's 64-bit bus and the MIG's native user-interface width and clock.

### 6.4 Bandwidth budget

| Path | Bandwidth | Note |
|---|---|---|
| DDR3 interface | 6.4 GB/s peak, ~5 GB/s usable | 32-bit × 1600 MT/s |
| DMA read port | 1.6 GB/s | 64-bit × 200 MHz (assumed axi_clk) |
| Array weight ingest (8×8) | 1.6 GB/s | one 8-byte tile row per clock |
| PCIe Gen2 x4 | ~2 GB/s per direction | host load/readback only, not on the compute path |

For compute-bound workloads (batched inference, classifiers) these limits are comfortable. For batch-1 LLM token generation the design is bandwidth-bound; `performance_model.md` works through the numbers for GPT-2 small.

## 7. Control and status registers (AXI4-Lite, 32-bit)

| Offset | Name | Fields |
|---|---|---|
| 0x00 | CTRL | [0] START (self-clear), [1] SOFT_RESET, [2] IRQ_EN |
| 0x04 | STATUS | [0] BUSY, [1] DONE (W1C), [2] ERR_AXI |
| 0x08 | DIM_M | M (16-bit) |
| 0x0C | DIM_N | N |
| 0x10 | DIM_K | K (≤ 4096) |
| 0x14–0x1C | ADDR_A/B/C | 32-bit base addresses |
| 0x20–0x28 | LD_A/B/C | leading dimensions (bytes) |
| 0x30 | CYC_TOTAL | core_clk cycles from START to DONE |
| 0x34 | CYC_ACTIVE | cycles the array performed MACs |
| 0x38 | CYC_STALL_LOAD | cycles the array waited on an A/B tile |
| 0x3C | CYC_STALL_STORE | cycles the array waited on C write-back |
| 0x40 | ID | 0x7147_0001 |

Utilisation = CYC_ACTIVE / CYC_TOTAL, read directly from hardware.

## 8. Clock domain crossing

- **CTRL.START, SOFT_RESET:** toggle synchronisers with a 4-phase req/ack handshake into `core_clk`.
- **Configuration registers** (dimensions, addresses): quasi-static. They are written before START, and the START handshake guarantees they are stable before `core_clk` logic samples them. An assertion checks that they do not change while BUSY.
- **Counters:** `core_clk` → `axi_clk` by snapshotting on DONE and synchronising the DONE flag through two flops; the counters are stable once DONE is set.
- **Tile buffers:** dual-clock RAM; the READY/CONSUMED handshake between the DMA (`axi_clk`) and the scheduler (`core_clk`) uses toggle synchronisers.

All CDC structures live in one file (`cdc_lib.sv`), with `ASYNC_REG` on every synchroniser flop. No other module has flops on unrelated clocks, and the XDC declares the two clocks as asynchronous groups.

## 9. Power

When no tile is READY, the PE array is held idle with a clock enable, so the DSP pipeline does not toggle. Operand isolation on the multipliers during drain is an optional addition. The effect of each is measured with the Vivado power report and recorded in `results.md`.

## 10. Verification

**UVM testbench (Vivado Simulator, UVM 1.2), run as a Tcl-scripted regression:**
- `axil_agent`: AXI4-Lite master driver and monitor for CSR access.
- `axi_mem_agent`: AXI4 slave responder with a backing memory model and configurable latency and backpressure, which stresses the scheduler and the ping-pong buffers.
- `ref_model`: SystemVerilog golden GEMM (INT32 loop).
- `scoreboard`: compares the C region of memory after DONE with the reference and checks that padding regions are untouched.
- Sequences: single tile; exact multiples of 8; ragged M/N/K; K = 1 and K = 4096; strided leading dimensions; back-to-back jobs; soft reset mid-job; memory backpressure sweep.
- Functional coverage: (M, N, K) mod 8 crosses, leading dimension ≠ N, burst lengths, each stall type, and buffer ping/pong transitions.

**Board-level simulation:** the same environment runs against `board_top` with the MIG and XDMA simulation models, which XSim supports, to check the integration before hardware.

**SystemVerilog assertions:** the buffer handshake never double-consumes a buffer; skew/deskew registers never over- or underflow; every AXI4-Lite request gets a response; configuration registers are stable while BUSY.

**Lint:** Vivado's RTL linter and synthesis warnings reviewed and kept clean on every commit; the build script fails on critical warnings.

**On hardware:** ILA cores (inserted from Tcl, not in the RTL) on the DMA and scheduler handshakes during bring-up; host-side comparison of every result against NumPy.

## 11. Implementation and measurement plan

1. **Core in simulation:** PE, array, skew/deskew, tile buffers, C buffer, scheduler, CSR, DMA; full UVM regression passing.
2. **Array + DDR3 on the board:** MIG generated from Tcl, temporary JTAG-to-AXI control path for bring-up, timing closure at the target `core_clk`, first real job from DDR.
3. **PCIe host path:** XDMA generated from Tcl; host software loads A and B, starts the job, polls DONE, reads C and the counters, and checks against NumPy.
4. **Optimisation and results:** INT8 DSP packing (two MACs per DSP48E1), tile-buffer sizing, and a utilisation table across tile sizes and memory latencies.

The numbers reported for each stage: fMAX and WNS, DSP/BRAM/LUT/FF usage, achieved DDR bandwidth, utilisation from the counters, GOPS, and end-to-end time from the host. All are logged in `results.md` against the commit that produced them.

## 12. Future work

- **Weight-streaming mode** for batch-1 LLM decode, so the array is not capped by its weight-ingest rate (see `performance_model.md` §2.11).
- **ASIC port** to an open-source flow (Yosys + OpenROAD, IHP SG13G2 130 nm). The RTL is kept technology-independent (no vendor primitives in the core, memories behind a wrapper, all CDC in one library) to make this possible.
- Bias, activation and requantisation blocks; 10G Ethernet ingest/egress.

## 13. Repository layout

```
tinygemm/
  README.md    block diagram, measured results, how to run
  docs/        this spec, performance model, diagrams, decisions.md, results.md
  rtl/         technology-independent core: pe.sv, systolic_array.sv, skew.sv, deskew.sv,
               sched.sv, tile_ram.sv, tile_buf.sv, c_buf.sv, dma_axi.sv, csr_axil.sv,
               cdc_lib.sv, tinygemm_top.sv
  fpga/        board top level, MIG/XDMA/clocking IP, constraints.xdc, build.tcl
  host/        PC-side software over the XDMA driver
  tb/uvm/      UVM environment: agents, reference model, scoreboard, sequences, tests
  tb/sva/      bindable assertion modules
  scripts/     XSim regression Tcl, matrix generation, Vivado report parsing
```

## 14. Open design questions

1. **Loop order** (N-outer vs M-outer): to be decided from the cycle estimate in `loop_order_and_cbuf.md`.
2. **Single vs double C buffer:** whether C write-back stalls compute at small K. The same estimate answers this before the C buffer RTL is written.
3. **DMA width:** whether to widen the DMA beyond 64 bits so a larger array can use more of the DDR3 bandwidth.
