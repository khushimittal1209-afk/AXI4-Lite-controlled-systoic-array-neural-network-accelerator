# AXI4-Lite Systolic Array Neural Network Accelerator
*A high-throughput hardware accelerator for matrix multiplication in machine learning workloads.*

---

## What Is This?

Imagine a convolutional neural network (CNN) inference workload processing high-resolution image frames on a general-purpose CPU. Every single output pixel requires hundreds of multiply-accumulate (MAC) operations, causing the processor to continuously fetch the same set of weights from external memory over and over. This redundant memory traffic starves the execution units, creates a massive memory bandwidth bottleneck, and wastes significant energy on bus transitions rather than computation. 

This is not a software problem. This is a hardware problem. To bypass the von Neumann bottleneck of general-purpose compute, we need a dedicated hardware spatial architecture that reuses weight data locally inside the computing fabric. **AXI4-Lite Controlled Systolic Array Neural Network Accelerator** is a register-mapped, hardware-gated matrix-multiplication engine designed specifically for these execution patterns. By arranging computation units in a 2D mesh, weights are loaded once and stationary, allowing activation data to stream horizontally and accumulators to flow vertically, maximizing data reuse.

The system is implemented entirely in synthesizable IEEE 1364-2001 Verilog, utilizing structured clock-gating cells, dual-bank SRAM-based ping-pong memory structures, and standard AXI4-Lite bus protocols to interface with a host processor.

## System Architecture

The hardware hierarchy is organized into modular layers as shown in the block diagram below:

```text
       +---------------------------------------------+
       |             Host Processor / BFM            |
       +---------------------------------------------+
                              | AXI4-Lite
                              v
       +---------------------------------------------+
       |               axi_lite_slave                |
       +---------------------------------------------+
          | Weight Wr      | Act Wr       | Register
          v                v              | Controls
    +------------+   +------------+       |
    | weight_buf |   |  act_buf   |       |
    +------------+   +------------+       |
          | Read           | Read         v
          | (64-bit)       | (64-bit)  +-------------------+
          v                v           |    Control FSM    |
    +-----------------------------+    | (accelerator_top) |
    |        systolic_array       |    +-------------------+
    |     (8x8 PE Grid, pe.v)     |              |
    +-----------------------------+              | Gating/Valid
                  |                              v
                  | col_result (8 x 32-bit Raw)
                  v
       +---------------------------------------------+
       |   Result Storage (RESULT_RAW / RESULT_SAT)  |
       +---------------------------------------------+
```

The system splits control and datapath concerns into clear layers:
* **Host Interface Layer**: The `axi_lite_slave` decodes 10-bit byte addresses to manage configuration registers (CTRL, STATUS, CLK_GATE_CTRL) and handle high-throughput memory-mapped write-burst emulation into the buffers.
* **Storage Layer**: Dual instances of `ping_pong_buffer` implement double-buffering. While the host writes new matrices into the back bank, the systolic array computes using the front bank.
* **Compute Layer**: The `systolic_array` structures the 8x8 processing element (PE) grid. The top-level controller coordinates state transitions and manages the activation skewing delay-chain.

## Phase 1 — PE MAC Datapath
The fundamental building block of the systolic array is the individual processing element (PE). Each PE contains a 8-bit multiplier, a 32-bit local accumulator, and control logic for weight-loading and activation propagation.
* ### Directed Verification
  Using a dedicated directed testbench, the PE was verified across multiple edge cases including signed negative-by-negative multiplication, saturation limits (clamping positive values to 127 and negative values to -128), and reset behavior. In total, **34/34 PE checks passed** successfully, verifying arithmetic correctness before array integration.

## Phase 2 — Systolic Array
The processing elements are tiled in an 8x8 grid where activations flow from west to east and partial sums flow from north to south.
* ### Wavefront Synchronization
  Because inputs must meet their corresponding weights at the correct spatial coordinates, activations must be skewed by one clock cycle per row, and results must be collected with a corresponding skew. End-to-end array execution was validated across identity, all-ones, and ramp weight matrices, confirming that the array obeys the latency equation $t_{exit} = i + c + 8$ for row $i$ and column $c$. A total of **192/192 systolic array checks across 3 weight patterns** passed validation.

## Phase 3 — Ping-Pong Buffer
To avoid stalling the host processor or the compute engine, dual-ported memory buffers are instantiated for both weight and activation data.
* ### Double-Buffered Isolation
  The buffers support independent read/write ports and a unified bank-switch interface. While the host writes to the back bank, the array reads from the front bank combinationally to avoid adding latency to the array stream. The testbench verified simultaneous read/write cycles and multi-swap address isolation, with **11/11 ping-pong buffer checks** passing cleanly.

## Phase 4 — AXI4-Lite Interface
The `axi_lite_slave` translates standard AXI bus reads and writes into register accesses and memory writes.
* ### Protocol Compliance
  A Master Bus Functional Model (BFM) was built to verify skewed write timings (address-first and data-first), read-data registration, and read-only protections on status registers. The interface passed **27/27 AXI4-Lite protocol checks**, ensuring robust interaction with any compliant host system.

## Phase 5 — Full Integration (In Progress)

The top-level integration module (`accelerator_top.v`) brings together the AXI slave, the ping-pong memories, the FSM controller, and the systolic array.
* ### Current Status
  The full integration wiring is complete, including the main FSM controller (orchestrating transitions through IDLE, SWAP, LOAD_WEIGHTS, STREAM, and DONE states) and the shift-register delay-chains for inputs. However, end-to-end verification currently fails due to a timing bug under active investigation.
* ### Technical Bug Log
  End-to-end simulation shows that the computed results stored in the raw memory are systematically offset by one index position. Specifically, the result of column $c$ equals the expected value of column $c-1$ (and row $i$ matches row $i-1$). This issue is isolated to a 1-cycle timing skew between the activation skewing delay-chain and the FSM's state transition boundaries. Because column 0 and row 0 are correct, data-packing, bit-slicing, and byte-order bugs are ruled out. Debugging is ongoing using targeted `$display` outputs and waveform analysis to align the control signals.

## Key Design Decisions

* **Why weight-stationary instead of output-stationary?**
  Weight-stationary architectures keep weights local to the PE registers, eliminating the need to read and write high-precision partial sums back and forth from external memories, which saves significant routing resources and power.
* **Why row-by-row weight loading over per-PE addressing?**
  Instead of routing individual address lines to 64 PEs, we stream weights row-by-row into the array using the horizontal activation paths during the `LOAD_WEIGHTS` phase, reducing routing congestion.
* **Why combinational reads in the ping-pong buffer?**
  Reading from the SRAM buffers combinationally ensures that data is presented to the systolic array's input registers immediately, keeping the critical path short and avoiding an extra cycle of startup latency.
* **Why dual-bank buffering?**
  Double-buffering allows the host to preload the next activation or weight matrix while the array is busy computing the current frame, maximizing hardware utilization.
* **Why Icarus Verilog?**
  We utilize Icarus Verilog for local, fast simulation runs during development, reserving heavy vendor tools like AMD Vivado for final synthesis, timing closure, and gate-level netlist verification.
* **Why active-low resets?**
  The design adopts an active-low reset (`aresetn`) to align with standard ARM AXI IP conventions, making it drop-in compatible with standard SoC interconnects.
* **Why silently ignore reserved writes?**
  To prevent invalid software writes from hanging the bus, the AXI slave returns an OKAY response for out-of-bounds register writes but ignores the data, maintaining system stability.
* **Why next-cycle self-clearing registers?**
  Control pulses like START or SOFT_RESET are designed to self-clear automatically on the next clock cycle, allowing the host to issue single-pulse triggers without needing separate clear transactions.

## What's Next

* **Resolve Phase 5 Timing Bug**: Align FSM state transition signals with the activation delay chain to correct the one-cycle result offset.
* **Phase 7 Golden-Model Verification**: Build a automated Python-based test runner that compares Verilog output memory dumps directly against NumPy golden matrix-multiplication outputs.
* **Phase 8 Vivado Synthesis**: Synthesize the design targeting a standard FPGA board (e.g., Xilinx Artix-7) to extract utilization, timing slack, and power estimations.

## Tech Stack

| Layer | Technology |
|---|---|
| RTL Language | Verilog (IEEE 1364-2001) |
| Simulator | Icarus Verilog (vvp) |
| Waveform Viewer | GTKWave |
| Bus Protocol | AXI4-Lite (32-bit data, 10-bit address) |
| Verification | Master BFM / Directed Testbenches |
| Scripting | Python 3 (NumPy) |
| Synthesis | Vivado Design Suite (Pending) |

---
*Computing at the speed of spatial structures.*
# AXI4-Lite Systolic Array Neural Network Accelerator
