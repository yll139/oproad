source $::env(SCRIPTS_DIR)/synth_preamble.tcl

source $::env(SYNTH_STOP_MODULE_SCRIPT)

if { [info exist ::env(SYNTH_GUT)] && $::env(SYNTH_GUT) == 1 } {
  hierarchy -check -top $::env(DESIGN_NAME)
  # /deletes all cells at the top level, which will quickly optimize away
  # everything else, including macros.
  delete $::env(DESIGN_NAME)/c:*
}

synthesize_check $::env(SYNTH_FULL_ARGS)

# rename registers to have the verilog register name in its name
# of the form \regName$_DFF_P_. We should fix yosys to make it the reg name.
# At least this is predictable.
renames -wire

# Optimize the design
opt -purge

# Technology mapping of adders
if {[info exist ::env(ADDER_MAP_FILE)] && [file isfile $::env(ADDER_MAP_FILE)]} {
  # extract the full adders
  extract_fa
  # map full adders
  techmap -map $::env(ADDER_MAP_FILE)
  techmap
  # Quick optimization
  opt -fast -purge
}

# Technology mapping of latches
if {[info exist ::env(LATCH_MAP_FILE)]} {
  techmap -map $::env(LATCH_MAP_FILE)
}

set dfflibmap_args ""
foreach cell $::env(DONT_USE_CELLS) {
  lappend dfflibmap_args -dont_use $cell
}

# Technology mapping of flip-flops
# dfflibmap only supports one liberty file
if {[info exist ::env(DFF_LIB_FILE)]} {
  dfflibmap -liberty $::env(DFF_LIB_FILE) {*}$dfflibmap_args
} else {
  dfflibmap -liberty $::env(DONT_USE_SC_LIB) {*}$dfflibmap_args
}
opt

puts "abc [join $abc_args " "]"
abc {*}$abc_args

# Replace undef values with defined constants
setundef -zero

# Splitting nets resolves unwanted compound assign statements in netlist (assign {..} = {..})
splitnets

# Remove unused cells and wires
opt_clean -purge

# Technology mapping of constant hi- and/or lo-drivers
hilomap -singleton \
        -hicell {*}$::env(TIEHI_CELL_AND_PORT) \
        -locell {*}$::env(TIELO_CELL_AND_PORT)

# Insert buffer cells for pass through wires
insbuf -buf {*}$::env(MIN_BUF_CELL_AND_PORTS)

# Reports
tee -o $::env(REPORTS_DIR)/synth_check.txt check

tee -o $::env(REPORTS_DIR)/synth_stat.txt stat {*}$stat_libs

# OpenROAD can reject several Yosys-only Verilog decorations before the design
# reaches link_design: escaped parameterized module names, generated escaped
# identifiers, and attributes such as dynports/src/hdlname.  Those tokens carry
# no connectivity information in the synthesized netlist, so normalize them at
# the file boundary and leave the physical netlist itself intact.
proc compare_token_length {a b} {
  return [expr {[string length $b] - [string length $a]}]
}

proc safe_verilog_identifier {prefix token idx} {
  set base $token
  if {[string index $base 0] == "\\"} {
    set base [string range $base 1 end]
  }
  regsub -all {[^A-Za-z0-9_]} $base "_" base
  regsub -all {_+} $base "_" base
  set base [string trim $base "_"]
  if {[string length $base] > 160} {
    set base [string range $base 0 159]
  }
  if {$base == "" || ![regexp {^[A-Za-z_]} $base]} {
    set base "${prefix}_${idx}"
  }
  return "${base}_${idx}"
}

proc stable_token_hash {token} {
  set hash 0
  foreach ch [split $token ""] {
    scan $ch %c code
    set hash [expr {(($hash * 131) + $code) & 0x7fffffff}]
  }
  return [format "%08x" $hash]
}

proc safe_escaped_identifier {token} {
  set base $token
  if {[string index $base 0] == "\\"} {
    set base [string range $base 1 end]
  }
  regsub -all {[^A-Za-z0-9_]} $base "_" base
  regsub -all {_+} $base "_" base
  set base [string trim $base "_"]
  if {[string length $base] > 120} {
    set base [string range $base 0 119]
  }
  if {$base == ""} {
    set base "net"
  }
  if {![regexp {^[A-Za-z_]} $base]} {
    set base "net_${base}"
  }
  return "${base}_[stable_token_hash $token]"
}

proc strip_yosys_attribute_line {line} {
  return [regexp {^[ \t]*\(\*.*\*\)[ \t]*$} $line]
}

proc sanitize_escaped_tokens_in_line {line} {
  set matches [regexp -indices -all -inline {\\[^ \t\r\n,;()]+} $line]
  if {[llength $matches] == 0} {
    return $line
  }

  set out ""
  set last 0
  foreach match $matches {
    lassign $match start end
    append out [string range $line $last [expr {$start - 1}]]
    set token [string range $line $start $end]
    append out [safe_escaped_identifier $token]
    set last [expr {$end + 1}]
  }
  append out [string range $line $last end]
  return $out
}

proc collect_module_name_map {filename} {
  set module_name_map {}
  set module_idx 0
  set in_file [open $filename r]
  while {[gets $in_file line] >= 0} {
    if {[regexp {^[ \t]*module[ \t]+([^ \t(]+)} $line -> module_name]} {
      if {![regexp {^[A-Za-z_][A-Za-z0-9_$]*$} $module_name]} {
        dict set module_name_map $module_name [safe_verilog_identifier "module" $module_name $module_idx]
        incr module_idx
      }
    }
  }
  close $in_file
  return $module_name_map
}

proc sanitize_generated_instance_names {filename} {
  # Parameterized modules can be emitted as escaped names such as
  # \$paramod\foo\WIDTH=s32'... .  OpenROAD's Verilog reader may reject these
  # before it reaches link_design, so map module type names to stable plain
  # identifiers.  Process the netlist linearly; large generated designs can
  # otherwise spend minutes in Tcl string-map over a huge escaped-token table.
  set module_name_map [collect_module_name_map $filename]
  set module_replacements {}
  foreach token [lsort -command compare_token_length [dict keys $module_name_map]] {
    lappend module_replacements $token [dict get $module_name_map $token]
  }

  set in_file [open $filename r]
  set tmp_filename "${filename}.tmp"
  set out_file [open $tmp_filename w]
  while {[gets $in_file line] >= 0} {
    if {[strip_yosys_attribute_line $line]} {
      continue
    }
    if {[llength $module_replacements] > 0} {
      set line [string map $module_replacements $line]
    }
    puts $out_file [sanitize_escaped_tokens_in_line $line]
  }
  close $in_file
  close $out_file
  file rename -force $tmp_filename $filename
}

# Write synthesized design
set synth_verilog $::env(RESULTS_DIR)/1_1_yosys.v
write_verilog -noexpr -nohex -nodec $synth_verilog
sanitize_generated_instance_names $synth_verilog
