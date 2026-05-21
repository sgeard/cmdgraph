# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Simon Geard
#
# Cross-language parity driver.
#   tclsh tools/parity/run.tcl [impl ...]      (default: tcl fortran cpp)
# Runs every scripts/*.in (plus a synthetic open-failure case) through each
# available implementation's run_file, comparing stdout/stderr/structured
# trailer to golden/ and cross-checking the impls against each other.
# Exit non-zero if any available impl mismatches golden.

set HERE [file dirname [file normalize [info script]]]
set SCR  [file join $HERE scripts]
set GOLD [file join $HERE golden]
set WORK [file join $HERE .work]
file mkdir $WORK

set ALL  {tcl fortran cpp}
set want [expr {[llength $argv] ? $argv : $ALL}]

# Synthetic open-failure path (literal, embedded verbatim in the error msg).
set NOFILE "tools/parity/scripts/does_not_exist.in"

# --- locate / build runners ---
proc have {impl} {
    global HERE
    switch $impl {
        tcl     { return 1 }
        fortran { return [file executable [file join $HERE bin runner_f]] }
        cpp     { return [file executable [file join $HERE bin runner_cpp]] }
    }
    return 0
}
proc runner_cmd {impl script res} {
    global HERE
    switch $impl {
        tcl     { return [list tclsh [file join $HERE runner.tcl] $script $res] }
        fortran { return [list [file join $HERE bin runner_f]  $script $res] }
        cpp     { return [list [file join $HERE bin runner_cpp] $script $res] }
    }
}

set avail {}
foreach impl $want {
    if {$impl eq "tcl"} { lappend avail tcl; continue }
    if {![have $impl]} {
        puts "building $impl runner ..."
        catch {exec make -C $HERE [expr {$impl eq "fortran" ? "fortran" : "cpp"}] 2>@1} blog
    }
    if {[have $impl]} {
        lappend avail $impl
    } else {
        puts "WARN: $impl runner unavailable — skipping"
        puts $blog
    }
}
puts "implementations: $avail"

# --- case list: every scripts/*.in + synthetic open-fail ---
set cases {}
foreach f [lsort [glob -nocomplain -directory $SCR *.in]] {
    lappend cases [list [file rootname [file tail $f]] $f]
}
lappend cases [list 10_open_fail $NOFILE]

proc slurp {p} { if {![file exists $p]} {return "<MISSING>"}; set h [open $p r]; set d [read $h]; close $h; return $d }

proc showdiff {label exp act} {
    puts "      --- $label expected ---"
    foreach l [split [string trimright $exp \n] \n] { puts "      | $l" }
    puts "      --- $label actual ---"
    foreach l [split [string trimright $act \n] \n] { puts "      | $l" }
}

set fail 0
foreach c $cases {
    lassign $c name script
    puts "\n=== $name ==="
    array unset cap
    foreach impl $avail {
        set base [file join $WORK ${name}.${impl}]
        set res  ${base}.res
        set cmd  [runner_cmd $impl $script $res]
        catch {exec {*}$cmd > ${base}.out 2> ${base}.err}
        set cap($impl,out) [slurp ${base}.out]
        set cap($impl,err) [slurp ${base}.err]
        set cap($impl,res) [slurp $res]
    }
    # Compare each available impl to golden.
    foreach impl $avail {
        set ok 1
        foreach ch {out err res} {
            set g [file join $GOLD ${name}.${ch}]
            set exp [slurp $g]
            set act $cap($impl,$ch)
            if {$exp eq "<MISSING>"} {
                puts "  \[golden $ch missing\]  ($impl) — capturing nothing, author golden"
                continue
            }
            if {$act ne $exp} {
                set ok 0
                puts "  FAIL $impl/$ch"
                showdiff $ch $exp $act
            }
        }
        if {$ok} { puts "  PASS $impl (vs golden)" } else { set fail 1 }
    }
    # Cross-impl parity (informational): all available impls identical?
    if {[llength $avail] > 1} {
        set ref [lindex $avail 0]
        foreach ch {out err res} {
            foreach impl [lrange $avail 1 end] {
                if {$cap($impl,$ch) ne $cap($ref,$ch)} {
                    puts "  XPAR diff $ref vs $impl on $ch"
                }
            }
        }
    }
}

puts "\n[expr {$fail ? {RESULT: FAIL — see mismatches above} : {RESULT: PASS — all available impls match golden}}]"
exit $fail
