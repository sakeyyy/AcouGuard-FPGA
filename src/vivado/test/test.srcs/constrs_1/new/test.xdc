# AX7021 (Zynq) - J15: 4 x INMP441 + ST7789V; J16: YYNMOS-4 controls
# PCB actual physical positions: U1 FRONT, U2 LEFT, U3 RIGHT, U4 BACK
# This XDC is for lcd_test.v with a 4-bit motor_pwm top-level port (16 logical ports).
# LVCMOS33 = 3.3V GPIO, NEVER 5V on FPGA signal pins.

# PL clock 50 MHz
set_property PACKAGE_PIN Y9 [get_ports clk_50m]
set_property IOSTANDARD LVCMOS33 [get_ports clk_50m]
create_clock -period 20.000 -name clk_50m [get_ports clk_50m]

# J15 microphone shared I2S
# J15-3 -> microphone SCK
set_property PACKAGE_PIN T21 [get_ports mic_sck]
set_property IOSTANDARD LVCMOS33 [get_ports mic_sck]
# J15-5 -> microphone WS
set_property PACKAGE_PIN U20 [get_ports mic_ws]
set_property IOSTANDARD LVCMOS33 [get_ports mic_ws]

# J15-7 -> PCB U1 FRONT
set_property PACKAGE_PIN Y19 [get_ports mic_front_sd]
set_property IOSTANDARD LVCMOS33 [get_ports mic_front_sd]
# J15-9 -> PCB U2 LEFT
set_property PACKAGE_PIN J21 [get_ports mic_left_sd]
set_property IOSTANDARD LVCMOS33 [get_ports mic_left_sd]
# J15-13 -> PCB U3 RIGHT  (IMPORTANT: P16, not K21)
set_property PACKAGE_PIN P16 [get_ports mic_right_sd]
set_property IOSTANDARD LVCMOS33 [get_ports mic_right_sd]
# J15-11 -> PCB U4 BACK   (IMPORTANT: K21, not P16)
set_property PACKAGE_PIN K21 [get_ports mic_back_sd]
set_property IOSTANDARD LVCMOS33 [get_ports mic_back_sd]

# J15 LCD ST7789V 240x320
# J15-4 -> LCD CS
set_property PACKAGE_PIN U21 [get_ports lcd_cs]
set_property IOSTANDARD LVCMOS33 [get_ports lcd_cs]
# J15-6 -> LCD RST
set_property PACKAGE_PIN V20 [get_ports lcd_rst]
set_property IOSTANDARD LVCMOS33 [get_ports lcd_rst]
# J15-8 -> LCD DC
set_property PACKAGE_PIN AA19 [get_ports lcd_dc]
set_property IOSTANDARD LVCMOS33 [get_ports lcd_dc]
# J15-10 -> LCD MOSI
set_property PACKAGE_PIN J22 [get_ports lcd_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports lcd_mosi]
# J15-12 -> LCD SCK
set_property PACKAGE_PIN J20 [get_ports lcd_sck]
set_property IOSTANDARD LVCMOS33 [get_ports lcd_sck]

# J16 YYNMOS-4 control signals (3.3V PWM from FPGA)
# J16-3  (FPGA V12) -> YYNMOS PWM1, FRONT
set_property PACKAGE_PIN V12 [get_ports {motor_pwm[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {motor_pwm[0]}]
# J16-5  (FPGA U12) -> YYNMOS PWM2, LEFT
set_property PACKAGE_PIN U12 [get_ports {motor_pwm[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {motor_pwm[1]}]
# J16-7  (FPGA U9)  -> YYNMOS PWM3, RIGHT
set_property PACKAGE_PIN U9 [get_ports {motor_pwm[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {motor_pwm[2]}]
# J16-9  (FPGA T6)  -> YYNMOS PWM4, BACK
set_property PACKAGE_PIN T6 [get_ports {motor_pwm[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {motor_pwm[3]}]

# Physical power wires: NOT controlled or constrained by this XDC.
# J16-1 is GND; J16-2 is +5V (board rail); J16-37/38 are GND.
# YYNMOS signal GND1..4 -> J16 GND (e.g. pin 1).
# YYNMOS DC+ / DC- are MOTOR LOAD POWER, not GPIO logic power.
# DO NOT connect DC+ to J16-2 (+5V) until all motors' 5V rating,
# startup/stall current, and available AX7021 5V power budget are verified.
# Safer default: independent appropriately rated 5V motor supply -> DC+/DC-.
# Motors connect individually to YYNMOS OUT1..OUT4 +/-.
