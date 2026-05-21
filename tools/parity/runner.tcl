# Parity runner — Tcl.  Usage: tclsh runner.tcl <script> <result-file>
# Builds the canonical parity graph (see GRAPH.md), run_file the script with
# echo on, then writes the normalised structured trailer to <result-file>.
# stdout/stderr are the compared streams.

set here [file dirname [file normalize [info script]]]
::tcl::tm::path add [file join $here .. .. tcl]
package require cmdgraph

proc act_echo  {args} { puts "echo: [lindex $args 0]";        return "" }
proc act_add   {args} { puts "sum: [expr {[lindex $args 0] + [lindex $args 1]}]"; return "" }
proc act_save  {args} { puts "save: ok";                      return "" }
proc act_send  {args} { puts "send: ok";                      return "" }
proc act_scale {args} { puts "scale: ok";                     return "" }
proc act_open  {args} {
    set id [lindex $args 0]
    if {$id <= 0} { return "" }
    return $id
}
proc act_zero  {args} { return "0" }
proc act_where {args} { puts "where: ctx=[cmdgraph::context]"; return "" }
proc act_update {args} { puts "update: [lindex $args 0]";      return "" }
proc enter_detail {} { puts "entered detail ctx=[cmdgraph::context]" }

proc build {} {
    set graph {
        root {
            prompt {root> }
            commands {
                {e(cho)}  {action act_echo args {{text rest}} help {echo text}}
                {ad(d)}   {action act_add args {{x int} {y int}} help {add two ints}}
                {s(ave)}  {action act_save help {save}}
                {s(end)}  {action act_send help {send}}
                {sc(ale)} {action act_scale args {{f real}} help {scale}}
                {o(pen)}  {do_goto detail act_open args {{id int}} help {open id}}
                {z(ero)}  {do_goto detail act_zero help {zero-ctx do_goto}}
                {g(o)}    {goto detail help {go}}
                {q(uit)}  {quit help {quit}}
            }
        }
        detail {
            prompt {detail> }
            on_enter enter_detail
            commands {
                {w(here)}  {action act_where help {show context}}
                {u(pdate)} {do_pop act_update args {{note rest}} help {update note}}
                {b(ack)}   {pop help {back}}
                {q(uit)}   {quit help {quit}}
            }
        }
    }
    return [cmdgraph::Engine new $graph root]
}

set script  [lindex $argv 0]
set resfile [lindex $argv 1]

set eng [build]
set r [$eng run_file $script 1]

set ok      [dict get $r ok]
set stat    [dict get $r stat]
set line    [dict get $r line]
set lmsg    [$eng last_message]
set lerr    [$eng last_error]
set state   [$eng current_state]

# Normalise rc: open-failure discriminator is ok==0 && line==0 (P0).
if {!$ok && $line == 0} {
    set rc OPEN_FAIL
} elseif {$ok} {
    set rc OK
} else {
    set rc [string toupper $stat]
}

set f [open $resfile w]
puts $f "ok=$ok"
puts $f "rc=$rc"
puts $f "line=$line"
puts $f "state=$state"
puts $f "last_message=$lmsg"
puts $f "last_error=$lerr"
close $f
