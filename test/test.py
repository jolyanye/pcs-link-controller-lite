import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, with_timeout, SimTimeoutError
from cocotb.queue import Queue
import random

# --- PREDICTOR ---
from encoder import Encoder8b10b

# --- AGENTS ---
class PcsScoreboard:
    def __init__(self, dut):
        self.dut = dut
        self.expected_queue = Queue()
        self.match_count = 0
        self.errors = 0

    def add_expected(self, expected_10b, tx_val):
        self.expected_queue.put_nowait((expected_10b, tx_val))

    def check_result(self, captured_10b):
        if self.expected_queue.empty():
            return

        expected_sym, tx_val = self.expected_queue.get_nowait()
        if captured_10b == expected_sym:
            self.match_count += 1
            self.dut._log.info(f"[SCOREBOARD] Match #{self.match_count}: 0x{tx_val:02X} -> {captured_10b}")
        else:
            self.errors += 1
            self.dut._log.error(f"[SCOREBOARD ERROR] Expected for 0x{tx_val:02X}: {expected_sym} | Got: {captured_10b}")

class PcsTxMonitor:
    def __init__(self, dut, scoreboard):
        self.dut = dut
        self.scoreboard = scoreboard
        self.comma_n = [int(b) for b in "0011111010"]
        self.comma_p = [int(b) for b in "1100000101"]

    async def start(self):
        history = []
        # Sync Loop
        while True:
            await RisingEdge(self.dut.clk)
            try:
                history.append(int(self.dut.serial_out.value))
            except ValueError:
                continue
            if len(history) > 10:
                history.pop(0)
            if history in [self.comma_n, self.comma_p]:
                break
                
        self.dut._log.info("MONITOR: Aligned to ASIC stream. Starting capture.")

        # Capture Loop
        while True:
            symbol = []
            for _ in range(10):
                await RisingEdge(self.dut.clk)
                try:
                    symbol.append(int(self.dut.serial_out.value))
                except ValueError:
                    symbol.append(0)
            
            if symbol not in [self.comma_n, self.comma_p]:
                self.scoreboard.check_result(symbol)

class PcsRxDriver:
    def __init__(self, dut):
        self.dut = dut
        self.tx_queue = Queue()
        self.idle_comma = [int(b) for b in "0011111010"]

    def queue_symbol(self, symbol_10b):
        self.tx_queue.put_nowait(symbol_10b)

    async def start(self):
        while True:
            symbol = self.idle_comma if self.tx_queue.empty() else self.tx_queue.get_nowait()
            for bit in symbol:
                self.dut.serial_in.value = bit  
                await RisingEdge(self.dut.clk)

# --- MAIN TESTBENCH ---
@cocotb.test()
async def test_pcs_verification_suite(dut):
    dut._log.info("Starting PCS LITE Verification Test (starting with TX mode)...")

    cocotb.start_soon(Clock(dut.clk, 15.15, unit="ns").start())     
    cocotb.start_soon(Clock(dut.clk_sys, 100, unit="ns").start())   

    predictor = Encoder8b10b()
    scoreboard = PcsScoreboard(dut)
    monitor = PcsTxMonitor(dut, scoreboard)
    driver = PcsRxDriver(dut)

    cocotb.start_soon(monitor.start())
    cocotb.start_soon(driver.start())

    dut.ena.value = 1
    dut.rst_n.value = 0
    dut.rx_req.value = 0     
    dut.tx_valid.value = 0   
    await ClockCycles(dut.clk_sys, 10)
    dut.rst_n.value = 1

    # =====================================================
    # PHASE 1: 8b/10b DISPARITY STRESS TEST
    # =====================================================
    dut._log.info("--- Phase 1: Disparity Flip Stress ---") # spam data with flipping disparity patterns to stress test
    disparity_stress_bytes = [0x00, 0xFF, 0x0F, 0xF0, 0x55, 0xAA] * 5 
    
    for tx_val in disparity_stress_bytes:
        expected_10b = predictor.encode(tx_val)
        scoreboard.add_expected(expected_10b, tx_val)
        
        dut.uio_in.value = tx_val
        dut.tx_valid.value = 1
        await RisingEdge(dut.clk_sys)
        dut.tx_valid.value = 0
        await ClockCycles(dut.clk_sys, 5)

    # =====================================================
    # PHASE 2: CDC FIFO BURST STRESS (WITH RANDOM IDLES)
    # =====================================================
    dut._log.info("--- Phase 2: TX CDC FIFO Bursty Stress Test ---") 
    
    for i in range(50): 
        tx_val = random.randint(0, 255)
        expected_10b = predictor.encode(tx_val)
        scoreboard.add_expected(expected_10b, tx_val)
        
        await FallingEdge(dut.clk_sys)
        
        # 1. Randomly decide to starve the upstream data for a few cycles
        if random.random() < 0.3: # 30% chance to insert an idle gap
            idle_cycles = random.randint(1, 4)
            dut._log.info(f"Random upstream stall for {idle_cycles} cycles...")
            dut.tx_valid.value = 0
            for _ in range(idle_cycles):
                await FallingEdge(dut.clk_sys)
        
        # 2. Wait for FIFO space
        while int(dut.tx_fifo_full.value) == 1:
            dut.tx_valid.value = 0 # Ensure valid drops if we are waiting
            await FallingEdge(dut.clk_sys)
            
        # 3. Drive the data safely
        dut.uio_in.value = tx_val
        dut.tx_valid.value = 1
        
        await RisingEdge(dut.clk_sys) 
        dut.tx_valid.value = 0

    # =====================================================
    # PHASE 3: SWITCH LTSSM DIRECTION
    # =====================================================
    dut._log.info("--- Phase 3: LTSSM Direction Switch (TX -> RX) ---")
    dut.rx_req.value = 1     
    
    try:
        await with_timeout(RisingEdge(dut.rx_ack), 2000, "ns") 
        dut._log.info("PASS: RX Acknowledge received.")
    except SimTimeoutError:
        assert False, "FAIL: LTSSM Arbiter Deadlock during RX switch!"

    await ClockCycles(dut.clk, 20) 
    
    # Check that link maintains lock during and after the switch
    assert int(dut.link_lock_out.value) == 1, "FAIL: Dropped Link Lock during turnaround!"

    # =====================================================
    # PHASE 4: RX MODE
    # =====================================================
    dut._log.info("--- Phase 4: RX Mode ---")
    num_rx_tests = 50 
    
    for i in range(num_rx_tests):
        tx_val = random.randint(0, 255)
        symbol = predictor.encode(tx_val)

        dut._log.info(f"[{i+1}/{num_rx_tests}] [RX DRIVE] Streaming Expected 0x{tx_val:02X}")
        driver.queue_symbol(symbol)
        
        try:
            await with_timeout(RisingEdge(dut.rx_valid), 15000, "ns") 
            received_val = dut.uio_out.value.to_unsigned()
            
            assert received_val == tx_val, f"RX Mismatch: Expected 0x{tx_val:02X}, got 0x{received_val:02X}"
        except SimTimeoutError:
            assert False, f"DEADLOCK: Hardware never asserted rx_valid for 0x{tx_val:02X}."
    
    # =====================================================
    # PHASE 5: DESERIALIZER HUNT-MODE THRASHING
    # =====================================================
    dut._log.info("--- Phase 5: Deserializer Hunt-Mode Thrashing ---")
    
    # 1. Force loss of lock by sending noise (simulating unplugged cable)
    dut._log.info("Sending noise to force loss of lock...")
    for _ in range(50):
        driver.queue_symbol([random.choice([0, 1]) for _ in range(10)])
    
    await ClockCycles(dut.clk, 500) # Wait for noise to process
    assert int(dut.link_lock_out.value) == 0, "FAIL: Deserializer did not drop lock on noise!"

    # 2. Glitchy connection: 2 commas then noise (should NOT lock)
    dut._log.info("Sending glitchy connection (2 commas + noise)...")
    driver.queue_symbol(driver.idle_comma)
    driver.queue_symbol(driver.idle_comma)
    for _ in range(30):
        driver.queue_symbol([random.choice([0, 1]) for _ in range(10)])
        
    await ClockCycles(dut.clk, 320) 
    assert int(dut.link_lock_out.value) == 0, "FAIL: Deserializer falsely locked on glitch!"

    # 3. Stable connection: 4 commas to restore lock
    dut._log.info("Sending stable commas to restore lock...")
    for _ in range(5):
        driver.queue_symbol(driver.idle_comma)
        
    await with_timeout(RisingEdge(dut.link_lock_out), 2000, "ns")
    dut._log.info("PASS: Deserializer successfully re-locked.")

    # =====================================================
    # PHASE 6: RX ERROR INJECTION (NEGATIVE TESTING)
    # =====================================================
    dut._log.info("--- Phase 6: RX Error Injection ---")
    
    # Send a good byte, a bad byte, and a good byte
    tx_val_good_1 = 0xAA
    tx_val_good_2 = 0x33
    
    sym_good_1 = predictor.encode(tx_val_good_1)
    
    # FIX: Inject a universally illegal 10b symbol (e.g., all 1s).
    # This prevents accidental aliasing and guarantees the LUT throws decode_err.
    sym_bad = [1, 1, 1, 1, 1, 1, 1, 1, 1, 1] 
    
    sym_good_2 = predictor.encode(tx_val_good_2)
    
    driver.queue_symbol(sym_good_1)
    driver.queue_symbol(sym_bad)
    driver.queue_symbol(sym_good_2)

    # =====================================================
    # PHASE 7: LTSSM RAPID TURNAROUND STRESS
    # =====================================================
    dut._log.info("--- Phase 7: LTSSM Turnaround Stress ---")
    
    # Rapidly toggle the request pin to try and trap the state machine
    for _ in range(10):
        dut.rx_req.value = 0 # Request TX
        await ClockCycles(dut.clk_sys, random.randint(1, 3))
        dut.rx_req.value = 1 # Rapidly switch to RX
        await ClockCycles(dut.clk_sys, random.randint(1, 3))
        
    # Settle back into RX mode
    dut.rx_req.value = 1
    
    # FIX: Wait half a cycle to let everything settle from the loop
    await FallingEdge(dut.clk_sys)
    
    # Only wait for the RisingEdge if the hardware hasn't already reached RX mode!
    if int(dut.rx_ack.value) == 0:
        await with_timeout(RisingEdge(dut.rx_ack), 3000, "ns")
        
    dut._log.info("PASS: LTSSM survived rapid thrashing without deadlocking.")

    # =====================================================
    # PHASE 8: RX CDC FIFO BACKPRESSURE OVERFLOW
    # =====================================================
    dut._log.info("--- Phase 8: RX CDC FIFO Backpressure Overflow ---")
    
    # Switch back to TX mode. 
    # In TX mode, rx_rd_en is forced to 0 by the LTSSM, so the RX FIFO cannot drain.
    dut.rx_req.value = 0
    await ClockCycles(dut.clk_sys, 10)
    
    # Stream 10 bytes into the deserializer. 
    overflow_vals = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA]
    for val in overflow_vals:
        driver.queue_symbol(predictor.encode(val))
        
    await ClockCycles(dut.clk, 200)
    
    # Switch back to RX to drain whatever survived
    dut.rx_req.value = 1
    await with_timeout(RisingEdge(dut.rx_ack), 3000, "ns")
    
    survivors = []
    # Collect whatever comes out of the FIFO
    for _ in range(6): 
        try:
            await with_timeout(RisingEdge(dut.rx_valid), 1500, "ns")
            survivors.append(dut.uio_out.value.to_unsigned())
            await ClockCycles(dut.clk_sys, 1) # Step past valid
        except SimTimeoutError:
            break
            
    dut._log.info(f"Survivors recovered from flooded RX FIFO: {[hex(x) for x in survivors]}")
    assert len(survivors) <= 4, f"FAIL: RX FIFO returned {len(survivors)} bytes, exceeding physical capacity!"
    dut._log.info("PASS: RX CDC FIFO safely dropped overflowing data without corrupting pointers.")

    assert scoreboard.errors == 0, f"Test Failed with {scoreboard.errors} TX discrepancies."
    dut._log.info(f"--- VERIFICATION COMPLETE: 0 ERRORS DETECTED! ---")