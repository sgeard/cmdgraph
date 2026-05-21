# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Simon Geard
#
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
# Auto-quit collision detection (B3). A subclass defining a do_q* command
# whose required prefix is itself a prefix of "quit" would clash with the
# auto-injected q(uit). The Shell must refuse construction with a clear
# diagnostic rather than silently producing an ambiguous shell.
# ----------------------------------------------------------------------------

# 6a. The collision case: req="q" (full="query") with no explicit quit.
oo::class create QueryShell {
    superclass cmdgraph::Shell
    constructor {} { next "q> " }
    method do_q(uery) {} { my puts "query ran" }
}
set rc [catch { QueryShell new } err]
check "auto-quit collision: refused"  $rc 1
check "auto-quit collision: names the conflict" \
    [string match *q(uery)* $err] 1
check "auto-quit collision: names q(uit)" \
    [string match *q(uit)* $err] 1

# 6b. Same shape, longer required prefix ("qui(ck)" → req="qui").
oo::class create QuickShell {
    superclass cmdgraph::Shell
    constructor {} { next "qk> " }
    method do_qui(ck) {} { my puts "quick" }
}
set rc [catch { QuickShell new } err]
check "auto-quit collision: qui(ck) refused"  $rc 1

# 6c. Defining do_q(uit) explicitly opts out of auto-injection — the
# coexistence of do_q(uery) and do_q(uit) is the user's call (and the
# engine reports the runtime ambiguity if "q" alone is typed).
oo::class create QueryWithQuit {
    superclass cmdgraph::Shell
    constructor {} { next "q> " }
    method do_q(uery) {} { my puts "query ran" }
    method do_q(uit)  {} { my puts "bye"; my exit }
}
set rc [catch { QueryWithQuit new } err]
check "auto-quit opt-out via do_q(uit)"   $rc 0
catch { [QueryWithQuit new] destroy }

# 6d. Spec resolving to full "quit" via different parens (qu(it)) opts out.
oo::class create QueryWithQuit2 {
    superclass cmdgraph::Shell
    constructor {} { next "q> " }
    method do_q(uery) {} { my puts "query ran" }
    method do_qu(it)  {} { my puts "bye"; my exit }
}
set rc [catch { QueryWithQuit2 new } err]
check "auto-quit opt-out via do_qu(it)"   $rc 0
catch { [QueryWithQuit2 new] destroy }

# 6e. A do_q* whose required prefix is NOT a prefix of "quit" is safe.
# req="qz" is not in {q, qu, qui, quit}; cmd "qz" matches qz(ap) only,
# cmd "q" matches q(uit) only. No ambiguity, so auto-inject proceeds.
oo::class create ZapShell {
    superclass cmdgraph::Shell
    constructor {} { next "z> " }
    method do_qz(ap) {} { my puts "zap" }
}
set rc [catch { ZapShell new } err]
check "auto-quit safe with disjoint q-prefix"  $rc 0
catch { [ZapShell new] destroy }

# ----------------------------------------------------------------------------
# 7. Suppressed out_chan (B2) — empty out channel must not raise.
# Engine convention: out_chan eq "" means "discard output". cmdloop used to
# bypass that by writing the prompt directly to $out_chan, which raised on
# a literal empty string. Now it routes through emit_prompt and is silent.
# ----------------------------------------------------------------------------

Minimal create m4
set in_r [make_input_pipe {{greet Quiet} quit}]
m4 set_io_channels $in_r "" ""
set rc [catch { m4 cmdloop } err]
close $in_r
check "suppressed out_chan: no error"         $rc 0
check "suppressed out_chan: action still ran" [m4 last_greeted] Quiet
check "suppressed out_chan: quit landed"      [[m4 engine] is_running] 0
m4 destroy

# ----------------------------------------------------------------------------

puts ""
puts "Passed: $pass"
puts "Failed: $fail"
exit [expr {$fail > 0}]
