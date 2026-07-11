# Rapid sampler for PSC2 (SCSI selection visibility) — captures the ROM's SCSI
# bus scan: which target IDs it selects and whether the mounted target responds
# with BSY. PSC2 latches scsi_dbg at the LAST SEL assertion; rapid reads catch
# successive scan steps.
#   quartus_stp_tcl -t scripts/sample_sel.tcl [n] | sort | uniq -c
#
# PSC2 = {at_sel_data[31:24]=ID bits on bus@SEL, scsi_dbg@SEL[23:16], live[15:0]}
#   @SEL byte: [23]out_en [22]SEL [21]BSY [20:19]target_bsy [18:17]target_MOUNTED [16]ICR_DATA
set n 120
if {$argc >= 1} { set n [lindex $argv 0] }

set hw ""
foreach h [get_hardware_names] { if {[string match "DE-SoC*" $h]} { set hw $h; break } }
if {$hw eq ""} {
    foreach h [get_hardware_names] {
        if {![catch {get_device_names -hardware_name $h} devs]} {
            foreach d $devs { if {[string match "*5CSE*" $d]} { set hw $h; break } }
        }
        if {$hw ne ""} break
    }
}
set dev ""
if {$hw ne ""} { foreach d [get_device_names -hardware_name $hw] { if {[string match "*5CSE*" $d]} { set dev $d; break } } }
if {$dev eq ""} { puts "NO DEVICE"; exit 1 }

set info [get_insystem_source_probe_instance_info -device_name $dev -hardware_name $hw]
array set idx {}
set i 0
foreach inst $info { if {[lindex $inst 3] eq "PSC2"} { set idx(PSC2) $i }; incr i }
if {![info exists idx(PSC2)]} { puts "NO PSC2 probe"; exit 1 }

start_insystem_source_probe -device_name $dev -hardware_name $hw
for {set s 0} {$s < $n} {incr s} {
    set v [read_probe_data -instance_index $idx(PSC2) -value_in_hex]
    scan $v %x nv
    set idb [expr {($nv>>24)&0xFF}]
    # decode the target ID being selected = the non-initiator bit (initiator is usually 0x80)
    puts [format "SEL idbits=%02X MOUNTED=%d%d target_bsy=%d%d BSY=%d" \
        $idb [expr {($nv>>18)&1}] [expr {($nv>>17)&1}] \
        [expr {($nv>>20)&1}] [expr {($nv>>19)&1}] [expr {($nv>>21)&1}]]
}
end_insystem_source_probe -device_name $dev -hardware_name $hw
