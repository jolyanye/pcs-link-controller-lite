import machine
from ttboard.demoboard import DemoBoard

def setup_dual_clocks():
    tt = DemoBoard.get()
    
    # Start the main 66 MHz link clock on the dedicated 'clk' pin
    tt.clock_project_PWM(66000000)
    print("Link Clock (66 MHz) started on dedicated clk pin.")

    # Grab the specific RP2040 hardware pin mapped to your ui_in
    ui_in_0_pin = tt.ui_in.pins[0]
    
    # Configure that pin to output a 10 MHz PWM square wave
    sys_clk_pwm = machine.PWM(ui_in_0_pin)
    sys_clk_pwm.freq(10000000)  # 10 MHz
    sys_clk_pwm.duty_u16(32768)
    print("System Clock (10 MHz) started on ui_in[0] pin.")

if __name__ == "__main__":
    setup_dual_clocks()