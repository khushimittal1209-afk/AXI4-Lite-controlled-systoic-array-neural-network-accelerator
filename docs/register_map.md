# AXI4-Lite Register Map — INT8 Systolic Array Accelerator

## 1  Overview

This document defines the AXI4-Lite register interface for the 8×8 INT8
weight-stationary systolic-array matrix-multiplication accelerator.

* **Data bus width:** 32 bits
* **Address bus width:** 10 bits (1 024-byte address space)
* **Byte-addressable**, word-aligned (all accesses are 32-bit-aligned;
  bits `[1:0]` of every address are zero).

---

## 2  Design Decisions

### 2.1  Weight & Activation Loading — memory-mapped block

Weights and activations are loaded through a **block of memory-mapped
addresses** (16 words each), rather than a single auto-incrementing
FIFO-style register.

**Justification:**
1. Each address maps deterministically to a known set of matrix elements,
   making partial updates and debug reads trivial.
2. No hidden internal counter state that the host must track or can
   accidentally desynchronise.
3. Idiomatic for AXI4-Lite — every address is independently
   read/writable, consistent with the "flat register file" model.
4. 8×8 = 64 INT8 values ÷ 4 per 32-bit word = 16 writes — a
   manageable number of transactions.

**Packing order (little-endian byte lane):**

| Byte Lane | 31:24   | 23:16   | 15:8    | 7:0     |
|-----------|---------|---------|---------|---------|
| Contents  | val[4i+3] | val[4i+2] | val[4i+1] | val[4i] |

where `i` is the word index (0–15) and `val[]` is the linear row-major
index into the 8×8 matrix.  Example: word 0 holds matrix elements
`[0][0], [0][1], [0][2], [0][3]` in byte lanes 0–3.

### 2.2  Result Readback — dual regions (raw + saturated)

Two result regions are provided:

| Region | Words | Content |
|--------|-------|---------|
| `RESULT_RAW` (0x0100–0x01FC) | 64 | Full 32-bit signed accumulator, one per word, row-major |
| `RESULT_SAT` (0x0200–0x023C) | 16 | Hardware-saturated INT8 results, 4 packed per word, same byte-lane order as weight/activation loads |

**Justification:**
* `RESULT_RAW` gives the host full-precision accumulator values for
  flexible post-processing, custom quantisation schemes, or debug
  inspection.
* `RESULT_SAT` provides the spec-required hardware saturation to INT8 in
  a compact 16-read sequence, matching the weight/activation packing for
  DMA-friendly symmetry.
* Exposing both costs only address decode logic (the underlying storage
  is shared); the host uses whichever view is appropriate.

---

## 3  Register Map

| Offset | Name | Width | Access | Description |
|--------|------|-------|--------|-------------|
| `0x000`–`0x03C` | `WEIGHT_DATA[0–15]` | 32 | W | Weight matrix load. Each word packs 4 signed INT8 weights in row-major order. Word `i` at offset `0x000 + 4·i`. Total: 16 words = 64 weights for the 8×8 matrix. |
| `0x040`–`0x07C` | `ACT_DATA[0–15]` | 32 | W | Activation matrix load. Same packing as `WEIGHT_DATA`. Word `i` at offset `0x040 + 4·i`. |
| `0x080` | `CTRL` | 32 | RW | **Control register** (see §3.1). |
| `0x084` | `STATUS` | 32 | R | **Status register** (see §3.2). |
| `0x088` | `CLK_GATE_CTRL` | 32 | RW | **Clock-gating control** (see §3.3). |
| `0x08C`–`0x0FC` | — | — | — | *Reserved.* Reads return `0x0000_0000`; writes ignored. |
| `0x100`–`0x1FC` | `RESULT_RAW[0–63]` | 32 | R | Raw 32-bit signed accumulator result. `RESULT_RAW[k]` at offset `0x100 + 4·k` holds `C[k/8][k%8]` (row-major). |
| `0x200`–`0x23C` | `RESULT_SAT[0–15]` | 32 | R | Saturated INT8 results, 4 packed per word (same byte-lane order as weight/activation). Word `i` at offset `0x200 + 4·i`. |

### 3.1  CTRL Register (0x080)

| Bits | Name | Reset | Description |
|------|------|-------|-------------|
| 0 | `START` | 0 | Write `1` to trigger computation. **Self-clearing**: hardware clears to `0` once the compute pipeline begins. Writing `0` has no effect. |
| 1 | `SOFT_RESET` | 0 | Write `1` to reset all internal state (buffers, PE accumulators, FSM). **Self-clearing.** Does not affect AXI interface logic itself. |
| 31:2 | — | 0 | Reserved. |

### 3.2  STATUS Register (0x084)

| Bits | Name | Reset | Description |
|------|------|-------|-------------|
| 0 | `BUSY` | 0 | `1` while computation is in progress. |
| 1 | `DONE` | 0 | `1` when the most recent computation has completed and results are available. Cleared when `START` is written. |
| 31:2 | — | 0 | Reserved. |

### 3.3  CLK_GATE_CTRL Register (0x088)

| Bits | Name | Reset | Description |
|------|------|-------|-------------|
| 7:0 | `ROW_GATE_EN` | 0x00 | Bit `i` = `1` **disables** (clock-gates) PE row `i`. Gated rows hold their state. |
| 15:8 | `COL_GATE_EN` | 0x00 | Bit `i` = `1` **disables** (clock-gates) PE column `i`. Gated columns hold their state. |
| 31:16 | — | 0 | Reserved. |

---

## 4  Address Map Summary Diagram

```
  0x000 ┌──────────────────────────┐
        │   WEIGHT_DATA [16 words] │  W
  0x040 ├──────────────────────────┤
        │   ACT_DATA    [16 words] │  W
  0x080 ├──────────────────────────┤
        │   CTRL                   │  RW
  0x084 │   STATUS                 │  R
  0x088 │   CLK_GATE_CTRL          │  RW
  0x08C │   (reserved)             │
        │   ...                    │
  0x100 ├──────────────────────────┤
        │   RESULT_RAW  [64 words] │  R
  0x200 ├──────────────────────────┤
        │   RESULT_SAT  [16 words] │  R
  0x240 ├──────────────────────────┤
        │   (unused to 0x3FF)      │
  0x3FF └──────────────────────────┘
```

---

## 5  Module & Signal Naming Conventions

### 5.1  Clock and Reset

| Signal | Convention | Used in |
|--------|-----------|---------|
| `aclk` | AXI clock (rising-edge) | `accelerator_top`, `axi_lite_slave`, `axi_lite_master_bfm` |
| `aresetn` | AXI reset, **active-low**, synchronous | Same AXI-facing modules |
| `clk` | Internal domain clock | `pe`, `systolic_array`, `ping_pong_buffer` |
| `rst_n` | Internal reset, **active-low**, synchronous | Same internal modules |

> **Convention:** All resets are **active-low** throughout the design.
> The top-level module connects `aclk → clk` and `aresetn → rst_n`
> to the internal hierarchy.

### 5.2  AXI4-Lite Signal Names

Standard ARM AMBA AXI4-Lite signal names are used with an `s_axi_` prefix
on the slave side and `m_axi_` on the master BFM side:

```
awaddr, awvalid, awready          Write Address channel
wdata,  wstrb,  wvalid, wready    Write Data channel
bresp,  bvalid, bready            Write Response channel
araddr, arvalid, arready          Read Address channel
rdata,  rresp,  rvalid, rready    Read Data channel
```

### 5.3  Internal Signal Naming Style

| Convention | Example | Meaning |
|-----------|---------|---------|
| `snake_case` | `weight_wr_en` | All signal names |
| `_reg` suffix | `state_reg` | Registered / flip-flop output |
| `_next` suffix | `state_next` | Combinational next-state value |
| `_n` suffix | `rst_n` | Active-low signal |
| `_en` suffix | `clk_en` | Enable signal |
| `_valid` / `_ready` suffix | `act_valid` | Handshake qualifier |
| `UPPER_CASE` | `ADDR_WIDTH` | Parameters and localparams |

### 5.4  File Naming

| Directory | Naming | Examples |
|-----------|--------|----------|
| `rtl/` | `<module_name>.v` | `pe.v`, `systolic_array.v` |
| `tb/` | `tb_<module_name>.v` or utility name | `tb_pe.v`, `axi_lite_master_bfm.v` |
| `sim/` | Simulation outputs | `phase0_check.out` |
| `docs/` | Documentation | `register_map.md` |
| `python/` | Python golden-model scripts | `golden_model.py` |
| `scripts/` | Build/run helper scripts | `run_phase1.sh` |
