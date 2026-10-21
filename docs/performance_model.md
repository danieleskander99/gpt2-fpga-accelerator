# TinyGEMM Performance Model

This document derives, from first principles, the throughput TinyGEMM should reach on its target board, and identifies what limits it. It starts from how a neural-network layer maps onto a matrix multiply and builds a short chain of equations, where each quantity is fixed by the model, fixed by the hardware, or chosen at run time. The worked numbers in §3 are for the Kintex-7 XC7K325T board and the 8×8 array. They are pre-silicon estimates and are replaced by measured values in `results.md` as bring-up progresses.

Companion diagram: `ai_layer_is_gemm.svg` (why a layer is a GEMM).

---

## 1. Definitions

| Symbol | Meaning | Set by |
|---|---|---|
| **K** | inputs per neuron = weights per neuron = dot-product length | the model (previous layer width) |
| **N** | neurons in the layer = outputs per sample | the model |
| **M** | samples processed together = rows of A = **batch** | run time |
| **P** | parameters = total weights in the model = Σ over layers of K×N | the model |
| **b** | bytes per weight (FP32 = 4, FP16 = 2, INT8 = 1, INT4 = 0.5) | quantisation choice |
| **R** | array size, R×R processing elements | hardware |
| **f** | compute clock | hardware |
| **BW** | usable memory bandwidth, bytes/s | hardware |
| **U** | utilisation = achieved ÷ peak, measured by the CSR counters | result |

A layer computes C[M×N] = A[M×K] × B[K×N], where A holds M input samples (one per row) and B holds the weights.

## 2. The chain of equations

**2.1 Work per layer**

    MACs_layer = M × K × N

**2.2 Work per sample (one image, one token)**

    MACs_sample = Σ_layers K × N
                = P                     for fully-connected / LLM linear layers
                ≥ P                     in general (convolutions reuse weights; attention adds weight-free MACs)

**2.3 Bytes of weights per pass**

    Bytes_weights = P × b

**2.4 Arithmetic intensity** (MACs performed per byte of weights fetched)

    I = MACs_layer ÷ (K × N × b) = M ÷ b          for a fully-connected layer
    I = M for INT8. Batching is the lever: each fetched weight serves M samples.
    Convolutions multiply this by the number of output positions per image.

**2.5 Peak compute**

    Peak = R² × f        [MAC/s]        (× 2 for "OPS" / "FLOPS")

**2.6 Memory time and compute time per pass**

    T_compute = MACs_sample × M ÷ Peak
    T_memory  = Bytes_weights ÷ BW          (independent of M: weights are fetched once per batch)

**2.7 Pass time and bottleneck**

    T_pass = max( T_compute , T_memory )
    bottleneck = compute  if T_compute > T_memory, else memory

**2.8 Roofline form of the same statement**

    Throughput [MAC/s] = min( Peak , BW × I )
    Ridge point:  I* = Peak ÷ BW     — the intensity (≈ batch size for INT8 FC layers) at which
                                       memory-bound becomes compute-bound.

**2.9 Utilisation**

    U = achieved MAC/s ÷ Peak
      = T_compute ÷ T_pass            (ideal; real U is lower by scheduling bubbles, tile loads, padding)

**2.10 Rate and latency**

    samples/s  = M ÷ T_pass           (images/s for a classifier, tokens/s for an LLM across all sequences)
    per-sequence tokens/s = 1 ÷ T_pass

**2.11 Weight-ingest limit of a weight-stationary array** (why the roofline is an upper bound)

    BW_ingest = R × b × f             bytes/s the array can accept as new weights (one tile row per clock)
    At M = 1 the array cannot exceed BW_ingest even if the DDR is faster.

## 3. Worked numbers for this design

**Hardware (Kintex-7 325T board, current design)**

| Quantity | Value | Note |
|---|---|---|
| R | 8 | parameterised; 16×16 and 28×28 are the scaled-up options |
| f | 200 MHz | target; to be confirmed by timing closure |
| Peak (8×8) | 64 × 200 M = **12.8 GMAC/s** = 25.6 GOPS | |
| Peak (28×28, 784 PEs, ~840 DSPs) | **157 GMAC/s** | full-chip option |
| BW | **5 GB/s** usable | 6.4 GB/s theoretical (32-bit DDR3-1600, 2 × MT41K256M16); to be confirmed by a DMA bandwidth test |
| b | 1 (INT8) | |
| I* (8×8) | 12.8 ÷ 5 = **2.56** | batch ≥ 3 is compute-bound |
| I* (28×28) | 157 ÷ 5 = **31** | batch ≥ 32 is compute-bound |
| BW_ingest (8×8) | 8 × 1 × 200 M = **1.6 GB/s** | caps batch-1 LLM decode below the DDR line |

**Model A: MNIST MLP 784 → 256 → 10**

| Quantity | Value |
|---|---|
| P | 784×256 + 256×10 = **203k** |
| MACs_sample | 203k (= P) |
| Bytes_weights | 203 kB |
| Batch M | 64 |
| T_compute | 64 × 203k ÷ 12.8G = **1.0 ms** per batch |
| T_memory | 203 kB ÷ 5 GB/s = **0.04 ms** per batch |
| Bottleneck | **compute** (I = 64 ≫ 2.56) |
| Rate | 64 ÷ 1.0 ms ≈ **60k images/s** (ideal; expect less from the 10→16 padding on the last layer) |

**Model B: GPT-2 small, token generation (decode), batch 1**

Per transformer layer: QKV 768→2304 (1.77M), attention-out 768→768 (0.59M), MLP-up 768→3072 (2.36M), MLP-down 3072→768 (2.36M) = 7.08M. Twelve layers = 85M. Output projection 768→50,257 = 38.6M.

| Quantity | Value |
|---|---|
| P | **124M** |
| MACs_sample (per token) | 124M (= P, excluding attention over the KV cache) |
| Bytes_weights | **124 MB** at INT8 (496 MB FP32, 62 MB INT4) |
| Batch M | 1 |
| T_compute (8×8) | 124M ÷ 12.8G = **9.7 ms** |
| T_memory | 124 MB ÷ 5 GB/s = **24.8 ms** |
| Bottleneck | **memory** (I = 1 < 2.56) |
| T_pass | 24.8 ms → **~40 tokens/s** roofline ceiling |
| U (ideal) | 9.7 ÷ 24.8 = **39%** |
| Weight-ingest limit (8×8, as designed) | 124 MB ÷ 1.6 GB/s = 78 ms → **~13 tokens/s** realistic without a weight-streaming mode |
| Full chip (157 GMAC/s) | T_compute 0.8 ms, T_memory still 24.8 ms → still 40 tokens/s, U = 3% |

**Model B, the batch slider (8×8)**

| M | T_compute | T_memory | T_pass | tokens/s total | per sequence | U |
|---|---|---|---|---|---|---|
| 1 | 9.7 ms | 24.8 ms | 24.8 ms | 40 | 40 | 39% |
| 2 | 19.4 ms | 24.8 ms | 24.8 ms | 81 | 40 | 78% |
| 2.56 | 24.8 ms | 24.8 ms | 24.8 ms | 103 | 40 | 100% |
| 4 | 38.8 ms | 24.8 ms | 38.8 ms | 103 | 26 | 100% |
| 8 | 77.5 ms | 24.8 ms | 77.5 ms | 103 | 13 | 100% |

**Model B, prompt processing (prefill)**: a 100-token prompt is one GEMM with M = 100. T_compute = 970 ms on the 8×8, T_memory = 24.8 ms → compute-bound, U ≈ 100%. This is why LLM serving quotes time-to-first-token (prefill, compute-bound) separately from tokens/s (decode, memory-bound).

## 4. Design conclusions

- **Batch-1 LLM decode is memory-bound on this board at any array size.** Adding DSPs does not raise tokens/s; it lowers utilisation. The ceiling is BW ÷ (P × b). The levers are b (INT4 halves the bytes) and M (batch several sequences).
- **The weight-stationary dataflow caps decode below the roofline** (§2.11). Reaching the 40 tokens/s ceiling needs a mode where weights stream and the activation vector stays put. This is planned as a v2 feature; v1 keeps the weight-stationary dataflow.
- **Classifiers and CNNs are compute-bound here**, so for them widening the array (R = 16, 28) pays off nearly linearly. This is where the 840 DSPs matter.
- **Utilisation counters are the ground truth.** CYC_ACTIVE ÷ CYC_TOTAL from the CSR block is U. Compare it with the ideal U in these tables; the gap is scheduling (tile loads, ragged edges, DMA bubbles), which is what the ping-pong buffers and loop order are there to shrink.
- **The three key inputs are measured, not assumed**: f comes from the post-route timing report, BW from a DMA bandwidth test, and U from the hardware counters. Each measurement is logged in `results.md` with the commit it came from, and §3 is updated to match.

## 5. Glossary

| Term | Meaning |
|---|---|
| Parameter / weight | One learned number in a weight matrix; P is the total |
| Sample | One complete input: one image, one token |
| Batch (M) | Samples processed together, sharing one fetch of the weights |
| MAC | Multiply-accumulate; = 2 OPs / FLOPs |
| GMAC/s, GOPS, TOPS | Throughput units; OPS = 2 × MAC/s |
| Quantisation | Converting weights to fewer bytes (b); INT8 is nearly lossless, INT4 costs some accuracy |
| Arithmetic intensity (I) | MACs per byte fetched; ≈ M for INT8 FC layers |
| Roofline | Throughput = min(Peak, BW × I); the ridge I* = Peak ÷ BW |
| Memory-bound / compute-bound | Which side of the ridge the workload sits on |
| Prefill / decode | Processing the prompt (large M, compute-bound) / generating tokens (M = 1 per sequence, memory-bound) |
| KV cache | Stored attention keys/values for earlier tokens; adds per-token bytes that grow with context |
| Utilisation (U) | Fraction of peak actually achieved; measured by hardware counters |
