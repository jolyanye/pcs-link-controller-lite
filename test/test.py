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
async def pcs_verification(dut):
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
    # PHASE 2: COVERAGE - CDC FIFO BURST STRESS
    # =====================================================
    dut._log.info("--- Phase 2: TX CDC FIFO Burst Test ---") # drive a burst of data to fill the TX FIFO and ensure proper backpressure handling without deadlocks
    
    for i in range(20): 
        tx_val = random.randint(0, 255)
        expected_10b = predictor.encode(tx_val)
        scoreboard.add_expected(expected_10b, tx_val)

        await FallingEdge(dut.clk_sys)
        
        while int(dut.tx_fifo_full.value) == 1:
            dut.tx_valid.value = 0 # Ensure valid drops if we are waiting
            await FallingEdge(dut.clk_sys)
            
        dut.uio_in.value = tx_val
        dut.tx_valid.value = 1
        await RisingEdge(dut.clk_sys) 
        dut.tx_valid.value = 0
    
    # Wait for the SerDes to completely drain the FIFO
    await ClockCycles(dut.clk_sys, 100)

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
    
    for i in range(50):
        tx_val = random.randint(0, 255)
        symbol = predictor.encode(tx_val)

        dut._log.info(f"[{i+1}/{50}] [RX DRIVE] Streaming Expected 0x{tx_val:02X}")
        driver.queue_symbol(symbol)
        
        try:
            await with_timeout(RisingEdge(dut.rx_valid), 15000, "ns") 
            received_val = dut.uio_out.value.to_unsigned()
            
            assert received_val == tx_val, f"RX Mismatch: Expected 0x{tx_val:02X}, got 0x{received_val:02X}"
        except SimTimeoutError:
            assert False, f"DEADLOCK: Hardware never asserted rx_valid for 0x{tx_val:02X}."
    
    # =====================================================
    # PHASE 5: DESERIALIZER LOCKING/RE-LOCKING TEST
    # =====================================================
    dut._log.info("--- Phase 5: Deserializer Locking/Re-locking Test ---")
    
    # Force loss of lock by sending noise
    dut._log.info("Sending noise to force loss of lock...")
    for _ in range(50):
        driver.queue_symbol([random.choice([0, 1]) for _ in range(10)])
    
    await ClockCycles(dut.clk, 500)
    assert int(dut.link_lock_out.value) == 0, "FAIL: Deserializer did not drop lock on noise!"

    # Send 2 commas then noise (should NOT lock)
    dut._log.info("Sending glitchy connection (2 commas + noise)...")
    driver.queue_symbol(driver.idle_comma)
    driver.queue_symbol(driver.idle_comma)
    for _ in range(30):
        driver.queue_symbol([random.choice([0, 1]) for _ in range(10)])
        
    await ClockCycles(dut.clk, 320) 
    assert int(dut.link_lock_out.value) == 0, "FAIL: Deserializer falsely locked on glitch!"

    # Send 4 commas to restore lock
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
    tx_val_bad    = 0x00
    tx_val_good_2 = 0x33
    
    sym_good_1 = predictor.encode(tx_val_good_1)
    sym_bad = predictor.encode(tx_val_bad)
    
    ones_count = sum(sym_bad[:6])
    if ones_count == 2:
        # RD+ State: Flip a '1' to 'zero' to create a block with only 1 one
        for i in range(6):
            if sym_bad[i] == 1:
                sym_bad[i] = 0
                dut._log.info(f"Flipped bit at index {i} (1->zero) to create invalid weight symbol (1 one).")
                break
    else:
        # RD- State: Flip a 'zero' to '1' to create a block with 5 ones
        for i in range(6):
            if sym_bad[i] == 0:
                sym_bad[i] = 1
                dut._log.info(f"Flipped bit at index {i} (zero->1) to create invalid weight symbol (5 ones).")
                break
            
    sym_good_2 = predictor.encode(tx_val_good_2)
    
    driver.queue_symbol(sym_good_1)
    driver.queue_symbol(sym_bad)
    driver.queue_symbol(sym_good_2)
    
    await with_timeout(RisingEdge(dut.rx_valid), 3000, "ns")
    assert dut.uio_out.value.to_unsigned() == tx_val_good_1, "FAIL: Good byte 1 corrupted."
    
    await ClockCycles(dut.clk_sys, 1) # Step past the current valid edge
    await with_timeout(RisingEdge(dut.rx_valid), 3000, "ns")
    assert dut.uio_out.value.to_unsigned() == tx_val_good_2, "FAIL: Decoder failed to drop invalid byte!"
    dut._log.info("PASS: Decoder successfully isolated and dropped the corrupted byte.")

    # =====================================================
    # PHASE 7: LTSSM RAPID TURNAROUND STRESS
    # =====================================================
    dut._log.info("--- Phase 7: LTSSM Turnaround Stress ---")
    
    # Rapidly toggle the request pin to switch modes
    for _ in range(10):
        dut.rx_req.value = 0
        await ClockCycles(dut.clk_sys, random.randint(1, 3))
        dut.rx_req.value = 1
        await ClockCycles(dut.clk_sys, random.randint(1, 3))
        
    dut.rx_req.value = 1
    await FallingEdge(dut.clk_sys)
    
    if int(dut.rx_ack.value) == 0:
        await with_timeout(RisingEdge(dut.rx_ack), 3000, "ns")
        
    dut._log.info("PASS: LTSSM survived rapid thrashing without deadlocking.")

    # =====================================================
    # PHASE 8: RX CDC FIFO BACKPRESSURE OVERFLOW
    # =====================================================
    dut._log.info("--- Phase 8: RX CDC FIFO Backpressure Overflow ---")
    
    # Switch back to TX mode
    dut.rx_req.value = 0
    await ClockCycles(dut.clk_sys, 10)
    
    # Overflow deserializer + FIFO
    overflow_vals = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA]
    for val in overflow_vals:
        driver.queue_symbol(predictor.encode(val))
        
    await ClockCycles(dut.clk, 200)
    
    # Switch back to RX to drain FIFO
    dut.rx_req.value = 1
    await with_timeout(RisingEdge(dut.rx_ack), 3000, "ns")
    
    survivors = []
    # Collect whatever comes out of the FIFO
    for _ in range(6): 
        try:
            await with_timeout(RisingEdge(dut.rx_valid), 1500, "ns")
            survivors.append(dut.uio_out.value.to_unsigned())
            await ClockCycles(dut.clk_sys, 1)
        except SimTimeoutError:
            break
            
    assert len(survivors) <= 4, f"FAIL: RX FIFO returned {len(survivors)} bytes, exceeding physical capacity!"
    dut._log.info("PASS: RX CDC FIFO safely dropped overflowing data without corrupting pointers.")

    # End of test
    assert scoreboard.errors == 0, f"Test Failed with {scoreboard.errors} errors."
    dut._log.info(f"--- VERIFICATION COMPLETE: 0 ERRORS DETECTED! ---")