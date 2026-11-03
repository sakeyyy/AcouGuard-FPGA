# Run from the repository root: xsdb board/run_jtag.tcl
# Optional: xsdb board/run_jtag.tcl <bit> <elf> <ps7_init.tcl>
# Use a complete, matching set. Does not program flash or persist name templates.
set root [file normalize [file join [file dirname [info script]] ..]]
set bit [file join $root board artifacts design_1_wrapper.bit]
set elf [file join $root board artifacts hearing_mlp.elf]
set init [file join $root board artifacts ps7_init.tcl]
if {$argc == 3} {lassign $argv bit elf init} elseif {$argc != 0} {error "Expected zero or three artifact arguments"}
foreach path [list $bit $elf $init] {if {![file exists $path]} {error "Missing artifact: $path"}}
connect
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 2000
targets -set -nocase -filter {name =~ "xc7z020*"}
fpga -file $bit
targets -set -nocase -filter {name =~ "ARM*#0"}
rst -processor
source $init
ps7_init
ps7_post_config
dow $elf
con
puts "Application running. UART1: 115200, 8N1."
