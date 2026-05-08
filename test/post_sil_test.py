from machine import Pin
import time
import random
import sys
import uselect
from encoder import Encoder8b10b

# 1. Pin Definitions
clk_sys = Pin(17, Pin.OUT)       # ui_in[0]
clk_link = Pin(16, Pin.OUT)      # Dedicated link clk
serial_in = Pin(18, Pin.OUT)     # ui_in[1]
rx_req = Pin(19, Pin.OUT)        # ui_in[2]
tx_valid = Pin(20, Pin.OUT)      # ui_in[3]
serial_out = Pin(33, Pin.IN)     # uo_out[0]
rx_ack = Pin(34, Pin.IN)         # uo_out[1]
rx_valid = Pin(37, Pin.IN)       # uo_out[4]
uio_pins = [Pin(i, Pin.OUT) for i in range(25, 33)] # uio[0:7]

# 2. Setup for Non-blocking Keyboard Input for Mode Switch
poll_obj = uselect.poll()
poll_obj.register(sys.stdin, uselect.POLLIN)

# 3. Helper Functions
def check_keyboard():
    if poll_obj.poll(0):
        char = sys.stdin.read(1)
        if char.lower() == 'm':
            return True
    return False

def tick_sys():
    clk_sys.value(1); clk_sys.value(0)

def tick_link():
    clk_link.value(1); clk_link.value(0)

def set_uio_dir(to_input):
    mode = Pin.IN if to_input else Pin.OUT
    for p in uio_pins: p.init(mode)

# 4. Initialization
print("--- PCS LITE STANDALONE TEST ---")
print("Type 'm' in the console and press Enter to toggle TX/RX")

current_mode = "TX"
rx_req.value(0)
set_uio_dir(to_input=False)
predictor = Encoder8b10b()

# 5. Main Loop
while True:
    # Check for Mode Toggle via REPL
    if check_keyboard():
        if current_mode == "TX":
            print("\n[Command] Switching to RX Mode...")
            rx_req.value(1)
            while rx_ack.value() == 0: tick_link() 
            current_mode = "RX"
            set_uio_dir(to_input=True) 
        else:
            print("\n[Command] Switching to TX Mode...")
            rx_req.value(0)
            while rx_ack.value() == 1: tick_link()
            current_mode = "TX"
            set_uio_dir(to_input=False) 

    # Generate and Validate
    test_val = random.randint(0, 255)
    expected_10b = predictor.encode(test_val)
    
    if current_mode == "TX":
        print(f"[TX] 0x{test_val:02X}...", end=" ")
        for i in range(8): uio_pins[i].value((test_val >> i) & 1)
        tx_valid.value(1); tick_sys(); tx_valid.value(0)
        tick_sys(); tick_sys()
        
        captured = []
        for _ in range(10):
            tick_link()
            captured.append(serial_out.value())
        print("PASS" if captured == expected_10b else f"FAIL! {captured}")
            
    else: # RX Mode
        print(f"[RX] 0x{test_val:02X}...", end=" ")
        for bit in expected_10b:
            serial_in.value(bit); tick_link()
            
        timeout = 0
        while rx_valid.value() == 0 and timeout < 20:
            tick_sys(); timeout += 1
            
        if timeout == 20:
            print("TIMEOUT")
        else:
            captured_val = 0
            for i in range(8): captured_val |= (uio_pins[i].value() << i)
            print("PASS" if captured_val == test_val else f"FAIL! 0x{captured_val:02X}")

    time.sleep(0.1)