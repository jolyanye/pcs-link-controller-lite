import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, with_timeout, SimTimeoutError
from cocotb.queue import Queue
import random

# --- 1. PREDICTOR (Golden Model) ---
class GoldenEncoder8b10b:
    def __init__(self):
        self.rd = 0  # 0 = Negative (RD-), 1 = Positive (RD+)
        self.lut_5b6b = {
            0: ("100111", "011000", True),  1: ("011101", "100010", True),
            2: ("101101", "010010", True),  3: ("110001", "110001", False),
            4: ("110101", "001010", True),  5: ("101001", "101001", False),
            6: ("011001", "011001", False), 7: ("111000", "000111", True),
            8: ("111001", "000110", True),  9: ("100101", "100101", False),
            10:("010101", "010101", False), 11:("110100", "110100", False),
            12:("001101", "001101", False), 13:("101100", "101100", False),
            14:("011100", "011100", False), 15:("010111", "101000", True),
            16:("011011", "100100", True),  17:("100011", "100011", False),
            18:("010011", "010011", False), 19:("110010", "110010", False),
            20:("001011", "001011", False), 21:("101010", "101010", False),
            22:("011010", "011010", False), 23:("111010", "000101", True),
            24:("110011", "001100", True),  25:("100110", "100110", False),
            26:("010110", "010110", False), 27:("110110", "001001", True),
            28:("001110", "001110", False), 29:("101110", "010001", True),
            30:("011110", "100001", True),  31:("101011", "010100", True)
        }
        self.lut_3b4b = {
            0: ("1011", "0100", True),  1: ("1001", "1001", False),
            2: ("0101", "0101", False), 3: ("1100", "0011", True),
            4: ("1101", "0010", True),  5: ("1010", "1010", False),
            6: ("0110", "0110", False)
        }

# --- 2. UVM-STYLE AGENTS ---
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
            return # Ignore idles

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

# --- 3. MAIN TESTBENCH ---
@cocotb.test()
async def test_pcs_verification_suite(dut):
    dut._log.info("Starting UVM-Style PCS Verification")

    # Start Clocks
    cocotb.start_soon(Clock(dut.clk, 15.15, unit="ns").start())     
    cocotb.start_soon(Clock(dut.clk_sys, 100, unit="ns").start())   

    # Instantiate Agents
    predictor = GoldenEncoder8b10b()
    scoreboard = PcsScoreboard(dut)
    monitor = PcsTxMonitor(dut, scoreboard)
    driver = PcsRxDriver(dut)

    # Launch background coroutines
    cocotb.start_soon(monitor.start())
    cocotb.start_soon(driver.start())

    # --- INITIALIZATION ---
    dut.ena.value = 1
    dut.rst_n.value = 0
    dut.rx_req.value = 0     
    dut.tx_valid.value = 0   
    await ClockCycles(dut.clk_sys, 10)
    dut.rst_n.value = 1

    # =====================================================
    # PHASE 1: COVERAGE - 8b/10b BOUNDARY DISPARITY STRESS
    # =====================================================
    dut._log.info("--- Phase 1: Disparity Flip Stress ---")
    # Sending bytes known to flip Running Disparity heavily (e.g., Dxx.x with high 1s or 0s)
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
    # PHASE 2: COVERAGE - FIFO BURST (FULL/EMPTY STRESS)
    # =====================================================
    dut._log.info("--- Phase 2: CDC FIFO Burst Test ---")
    # Hammer the tx_valid signal faster than the SerDes can drain it
    for i in range(20): # Assuming FIFO depth is 16, this forces an overflow condition check
        tx_val = random.randint(0, 255)
        expected_10b = predictor.encode(tx_val)
        scoreboard.add_expected(expected_10b, tx_val)
        
        dut.uio_in.value = tx_val
        dut.tx_valid.value = 1
        await RisingEdge(dut.clk_sys) 
        # Deliberately NOT waiting 5 cycles here to stress the FIFO write pointer
    
    dut.tx_valid.value = 0
    
    # Wait for the SerDes pipeline to drain the entire FIFO
    await ClockCycles(dut.clk_sys, 100)

    # =====================================================
    # PHASE 3: STATE HANDSHAKE (LTSSM TOGGLE)
    # =====================================================
    dut._log.info("--- Phase 3: LTSSM Direction Switch ---")
    dut.rx_req.value = 1     
    
    try:
        await with_timeout(RisingEdge(dut.rx_ack), 2000, "ns") 
        dut._log.info("PASS: RX Acknowledge received.")
    except SimTimeoutError:
        assert False, "FAIL: LTSSM Arbiter Deadlock during RX switch!"

    await ClockCycles(dut.clk, 20) 
    
    # Verify link maintains lock during and after the switch
    assert int(dut.link_lock_out.value) == 1, "FAIL: Dropped Link Lock during turnaround!"

    # Evaluate Scoreboard
    assert scoreboard.errors == 0, f"Test Failed with {scoreboard.errors} discrepancies."
    dut._log.info(f"--- VERIFICATION COMPLETE: {scoreboard.match_count} Transactions Matched! ---")