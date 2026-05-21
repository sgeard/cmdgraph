# kate: syntax Tcl/Tk;

tcl::tm::path add [file dirname [info script]]
package require cmdgraph

# Quick check: cmdgraph 1.2 is the version under test
if {![package vsatisfies [package provide cmdgraph] 1.2]} {
    puts stderr "ERROR: utest_shell needs cmdgraph 1.2 or later; got [package provide cmdgraph]"
    exit 1
}

set pass 0
set fail 0

proc check {label result expected} {
    global pass fail
    if {$result eq $expected} {
        puts "PASS: $label"
        incr pass
    } else {
        puts "FAIL: $label (got '$result', expected '$expected')"
        incr fail
    }
}

# ----------------------------------------------------------------------------
# Helpers: drive a Shell with a scripted stdin and capture its stdout.
# ----------------------------------------------------------------------------

# Create a pair of channels: writer side is `in_w`, reader side is `in_r`.
# The shell reads from `in_r`; the test writes its scripted input into `in_w`.
proc make_input_pipe {lines} {
    lassign [chan pipe] r w
    fconfigure $w -buffering line -translation lf
    fconfigure $r -buffering line -translation lf
    foreach line $lines { puts $w $line }
    close $w
    return $r
}

# Reflected write-only channel that appends everything written into a buffer.
namespace eval capture {
    variable buf ""
    proc reset {} { variable buf; set buf "" }
    proc text  {} { variable buf; return $buf }
    proc append_chunk {data} { variable buf; ::append buf $data }

    proc handler {cmd args} {
        switch -- $cmd {
            initialize { return {initialize finalize watch write} }
            finalize   { return }
            watch      { return }
            write      {
                set data [lindex $args 1]
                append_chunk $data
                return [string length $data]
            }
        }
    }
    proc channel {} {
        return [chan create write [namespace current]::handler]
    }
}

# Drive the shell with a list of input lines, capturing stdout. Returns
# the captured text.
proc run_shell {shell input_lines} {
    capture::reset
    set in_r [make_input_pipe $input_lines]
    set out  [capture::channel]
    $shell set_io_channels $in_r $out $out
    $shell cmdloop
    close $in_r
    close $out
    return [capture::text]
}

# ----------------------------------------------------------------------------
# 1. Minimal shell: do_* introspection, auto-injected quit, EOF exit.
# ----------------------------------------------------------------------------

oo::class create Minimal {
    superclass cmdgraph::Shell
    variable greeted
    constructor {} { next "min> "; set greeted "" }
    method do_g(reet) {name} { set greeted $name; my puts "Hello, $name" }
    method args_g(reet) {} { return {{name char}} }
    method help_g(reet) {} { return "Greet someone" }
    method last_greeted {} { return $greeted }
}

Minimal create m1
set out [run_shell m1 {{greet Simon} quit}]
check "minimal: greet ran"        [m1 last_greeted]                  "Simon"
check "minimal: greet output"     [string match *Hello,*Simon*  $out] 1
check "minimal: quit cleanly"     [[m1 engine] is_running]            0
m1 destroy

# EOF terminates the loop even without quit.
Minimal create m2
run_shell m2 {{greet Alice}}                 ;# no quit, just EOF
check "minimal: eof leaves engine alive"     [[m2 engine] is_running] 1
m2 destroy

# ----------------------------------------------------------------------------
# 2. Auto-quit is suppressed when the subclass defines its own do_q(uit).
# ----------------------------------------------------------------------------

oo::class create CustomQuit {
    superclass cmdgraph::Shell
    variable quit_count
    constructor {} { next "cq> "; set quit_count 0 }
    method do_q(uit) {} {
        incr quit_count
        my puts "bye ($quit_count)"
        my exit
    }
    method quit_count {} { return $quit_count }
}

CustomQuit create cq
run_shell cq {{quit}}
check "custom quit ran once" [cq quit_count] 1
cq destroy

# ----------------------------------------------------------------------------
# 3. Hooks: preloop/postloop, precmd/postcmd.
# ----------------------------------------------------------------------------

oo::class create Hooked {
    superclass cmdgraph::Shell
    variable trace
    constructor {} { next "h> "; set trace {} }
    method do_p(ing) {} { lappend trace ping }
    method preloop  {}        { lappend trace pre  }
    method postloop {}        { lappend trace post }
    method precmd   {line}    { lappend trace "pre:$line"; return $line }
    method postcmd  {rc line} { lappend trace "post:$rc:$line" }
    method trace    {}        { return $trace }
}

Hooked create hk
run_shell hk {ping quit}
set t [hk trace]
check "hook order: preloop first"  [lindex $t 0] pre
check "hook order: postloop last"  [lindex $t end] post
check "hook: precmd saw ping"      [expr {"pre:ping" in $t}]      1
check "hook: postcmd saw ping/ok"  [expr {"post:ok:ping" in $t}]  1
check "hook: ping action ran"      [expr {"ping" in $t}]          1
hk destroy

# Empty precmd return skips dispatch.
oo::class create Skipper {
    superclass cmdgraph::Shell
    variable n
    constructor {} { next "s> "; set n 0 }
    method do_b(ump) {} { incr n }
    method precmd {line} { return "" }
    method count {} { return $n }
}
Skipper create sk
run_shell sk {bump bump quit}
check "precmd '' skips dispatch" [sk count] 0
sk destroy

# ----------------------------------------------------------------------------
# 4. Arg validation flows through to the engine.
# ----------------------------------------------------------------------------

oo::class create Typed {
    superclass cmdgraph::Shell
    variable last
    constructor {} { next "t> "; set last "" }
    method do_a(dd) {x y} { set last [expr {$x + $y}]; my puts "= $last" }
    method args_a(dd) {} { return {{x int} {y int}} }
    method last {} { return $last }
}

Typed create t1
set out [run_shell t1 {{add 3 4} quit}]
check "typed args: action ran"  [t1 last] 7
check "typed args: output sum"  [string match *=*7* $out] 1
t1 destroy

Typed create t2
set out [run_shell t2 {{add 3 hello} quit}]
check "typed args: rejects bad int" [string match *expects*integer* $out] 1
t2 destroy

# ----------------------------------------------------------------------------
# 5. Built-in help still works (engine-provided when subclass doesn't override).
# ----------------------------------------------------------------------------

Minimal create m3
set out [run_shell m3 {help quit}]
check "built-in help lists greet"   [string match *g(reet)*    $out] 1
check "built-in help lists q(uit)"  [string match *q(uit)*     $out] 1
m3 destroy

# ----------------------------------------------------------------------------

puts ""
puts "Passed: $pass"
puts "Failed: $fail"
exit [expr {$fail > 0}]
