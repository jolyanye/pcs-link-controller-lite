<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The PCS Link Controller LITE is a compact, area-optimized Physical Coding Sublayer (PCS) block designed to mimic high-speed serial communication. It implements an 8b/10b encoding/decoding pipeline, asynchronous clock domain crossing (CDC) FIFOs, and a Link Training and Status State Machine (LTSSM) arbiter that manages a half-duplex, bidirectional shared data bus. The system operates across two asynchronous clock domains: a faster 66 MHz Link Clock for higher-speed serial transmission and a slower 10 MHz System Clock for parallel data handling.

## How to test

**1. Clock Configuration**
Before physical testing, the user must first program the demoboard's RP2040 microcontroller (using `pcs_lite_clocks.py`) to configure a 2nd clock: the slower 10 MHz System Clock (`clk_sys`) on the `ui_in[0]` pin.

**2. Testbench Setup**
The project includes a UVM-style testbench that uses Python agents (Driver, Monitor, Predictor, and Scoreboard) to validate the RTL across four coverage phases:
* **Phase 1 (Disparity Stress):** Drives highly skewed data patterns (e.g., `0x00`, `0xFF`) through the datapath to stress the combinational 8b/10b logic and force the Running Disparity (RD) state machine to toggle constantly.
* **Phase 2 (CDC FIFO Burst & Backpressure):** Executes a burst-write sequence that intentionally overwhelms the CDC FIFO. This phase verifies that the hardware correctly calculates its "full" state and that the transmitter properly respects backpressure without dropping bytes.
* **Phase 3 (LTSSM Direction Switch):** Triggers the `rx_req` signal to flip the half-duplex bus direction. It verifies the state machine handshake (`rx_ack`) and ensures the PCS maintains link lock during the transition.
* **Phase 4 (RX Mode Verification):** The testbench driver streams 50 randomized, 10-bit encoded symbols into the hardware. The Scoreboard ensures the internal deserializer and decoder accurately reconstruct the original 8-bit payloads with zero discrepancies.

**3. Hardware Validation (Optional)**
To physically validate the bidirectional link, the Tiny Tapeout demoboard can be interfaced with a 3.3V FPGA.
* **Physical Setup:** Ensure both boards share a common ground. At 66 MHz, signal integrity is paramount; use the shortest possible jumper wires for the two serial lines (TX and RX), ideally twisting them with ground wires to mitigate electromagnetic interference. Two additional connections (`ui_in[2]` and `uo_out[1]`) are required for the `rx_req` and `rx_ack` handshaking during mode-switching.
* **Testing:** The user can map the FPGA's physical switches to drive parallel data into the transmitter, while the receiver's output can be mapped to the demoboard's LEDs for real-time visual confirmation of the 8b/10b link.

## External hardware

Optional: FPGA and 5 jumper wires for hardware validation.
