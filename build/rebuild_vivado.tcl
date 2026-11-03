# Run: vivado -mode batch -source build/rebuild_vivado.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build output vivado]
file mkdir $out
open_project [file join $root src vivado test test.xpr]
update_compile_order -fileset sources_1
set bd [get_files -quiet */design_1.bd]
if {[llength $bd] != 1} {error "Expected exactly one design_1.bd"}
open_bd_design $bd
validate_bd_design -force
save_bd_design
generate_target all $bd
make_wrapper -files $bd -top
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 2
wait_on_run impl_1
set status [get_property STATUS [get_runs impl_1]]
if {![string match {*write_bitstream Complete*} $status]} {error "Implementation failed: $status"}
set bit [file join [get_property DIRECTORY [get_runs impl_1]] design_1_wrapper.bit]
if {![file exists $bit]} {error "Bitstream missing: $bit"}
file copy -force $bit [file join $out design_1_wrapper.bit]
write_hw_platform -fixed -include_bit -force -file [file join $out audio_platform.xsa]
open_run impl_1
report_utilization -file [file join $out utilization.rpt]
report_timing_summary -file [file join $out timing_summary.rpt]
report_drc -file [file join $out drc.rpt]
puts "BUILD OUTPUT: $out"
close_project
