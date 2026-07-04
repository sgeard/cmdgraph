# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Simon Geard
#

tcl::tm::path add [file dirname [info script]]
package require cmdgraph

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

# Probe records each action invocation so tests can assert what was called.
namespace eval probe {
    variable history {}
    proc reset {} { variable history; set history {} }
    proc record {name {value ""}} {
        variable history
        lappend history [list $name $value]
    }
    proc last  {} { variable history; return [lindex $history end] }
    proc count {} { variable history; return [llength $history] }
    proc all   {} { variable history; return $history }
}

# Test action procs
proc act_outer {args} { probe::record act_outer $args }
proc act_inner {args} { probe::record act_inner $args }
proc gate_ok   {args} { probe::record gate_ok   $args; return "go" }
proc gate_no   {args} { probe::record gate_no   $args; return "" }
proc act_throw {args} { probe::record act_throw $args; error "deliberate" }
proc custom_h  {args} { probe::record custom_h  $args }

set graph {
    outer {
        prompt "outer> "
        commands {
            a(ction) {action  act_outer       help "an action"}
            g(o)     {goto    inner           help "no-validate goto"}
            t(ry)    {do_goto inner gate_ok   help "succeeds"}
            f(ail)   {do_goto inner gate_no   help "fails validation"}
            e(rror)  {do_goto inner act_throw help "errors"}
            s(ave)   {action  act_outer       help "save"}
            s(ub)    {action  act_outer       help "sub"}
            p(op)    {pop                     help "pop edge at root"}
            q(uit)   {quit                    help "exit"}
        }
    }
    inner {
        prompt "inner> "
        commands {
            i(nner) {action act_inner help "inner action"}
            b(ack)  {pop              help "back"}
            help    {action custom_h  help "graph-defined help"}
        }
    }
}

# --- Construction & initial state ---

cmdgraph::Engine create eng $graph outer
check "starts in initial state"     [eng current_state] outer
check "is running at start"         [eng is_running]    1

# --- action edge: invokes proc, stays ---

probe::reset
eng dispatch "action"
check "action edge invokes proc"    [lindex [probe::last] 0] act_outer
check "action edge stays in state"  [eng current_state] outer

# --- prefix matching ---

probe::reset
eng dispatch "a"
check "single-char prefix matches"  [lindex [probe::last] 0] act_outer

probe::reset
eng dispatch "act"
check "mid prefix matches"          [lindex [probe::last] 0] act_outer

probe::reset
eng dispatch "action"
check "full name matches"           [lindex [probe::last] 0] act_outer

probe::reset
eng dispatch "actionz"
check "too-long name does not match" [probe::count] 0

probe::reset
eng dispatch "q"
check "exact-match command"         [eng is_running] 0

# rebuild for the rest of the tests
eng destroy
cmdgraph::Engine create eng $graph outer

# --- args reach the action ---

probe::reset
eng dispatch "action foo bar"
check "args reach the action"       [lindex [probe::last] 1] {foo bar}

probe::reset
eng dispatch {action "foo bar"}
check "quoted arg reaches action as one arg" [lindex [probe::last] 1] {{foo bar}}

probe::reset
check "unmatched quote returns error" [eng dispatch {action "foo bar}] error
check "unmatched quote not dispatched" [probe::count] 0

# --- ambiguity: s matches save AND sub via required prefix "s" ---

probe::reset
eng dispatch "s"
check "ambiguous prefix not dispatched" [probe::count] 0

probe::reset
eng dispatch "sav"
check "disambiguated prefix dispatches" [lindex [probe::last] 0] act_outer

# --- unknown command ---

probe::reset
eng dispatch "nonesuch"
check "unknown command not dispatched"  [probe::count] 0
check "unknown command stays in state"  [eng current_state] outer

# --- goto: pushes state, no proc call ---

probe::reset
eng dispatch "go"
check "goto changes state"          [eng current_state] inner
check "goto called no proc"         [probe::count] 0

eng dispatch "back"
check "pop returns to previous"     [eng current_state] outer

# --- do_goto: non-empty return transitions ---

probe::reset
eng dispatch "try"
check "do_goto non-empty transitions"  [eng current_state] inner
check "do_goto called gate proc"       [lindex [probe::last] 0] gate_ok
eng dispatch "back"

# --- do_goto: empty-string return stays ---

probe::reset
eng dispatch "fail"
check "do_goto empty stays"            [eng current_state] outer
check "do_goto empty called proc"      [lindex [probe::last] 0] gate_no

# --- do_goto: error in action ---

probe::reset
eng dispatch "error"
check "do_goto error stays"         [eng current_state] outer
check "do_goto error called proc"   [lindex [probe::last] 0] act_throw

# --- graph-defined help overrides the built-in ---

eng dispatch "go"
probe::reset
eng dispatch "help"
check "graph-defined help wins"     [lindex [probe::last] 0] custom_h
eng dispatch "back"

# --- pop from depth-1 stack exits engine ---

probe::reset
eng dispatch "pop"
check "pop from root exits"         [eng is_running] 0

eng destroy

# --- malformed graph: bad edge kind ---

set bad_graph {
    only {
        prompt "> "
        commands {
            x {oops some_proc}
        }
    }
}
set ok [catch {cmdgraph::Engine create bad $bad_graph only} err]
check "bad edge kind rejected"      $ok 1

# --- Construction-time validation ---

set bad_unknown_target {
    home {
        prompt "> "
        commands {
            g(o) {goto nowhere}
        }
    }
}
set ok [catch {cmdgraph::Engine create bad $bad_unknown_target home} err]
check "goto to unknown state rejected"  $ok 1

set bad_abstract_target {
    home {
        prompt "> "
        commands {
            g(o) {goto helpers}
        }
    }
    helpers {
        commands {
            x {action act_outer}
        }
    }
}
set ok [catch {cmdgraph::Engine create bad $bad_abstract_target home} err]
check "goto to abstract state rejected" $ok 1

set ok [catch {cmdgraph::Engine create bad $graph nope} err]
check "unknown initial state rejected"  $ok 1

# --- includes: shared command set ---

set inc_graph {
    common {
        commands {
            s(tyle) {action act_outer help "Set style"}
            l(ayer) {action act_outer help "Change layer"}
        }
    }
    line {
        prompt "line> "
        includes {common}
        commands {
            f(rom) {action act_inner help "Start point"}
        }
    }
}

cmdgraph::Engine create eng2 $inc_graph line

probe::reset
eng2 dispatch "from"
check "state's own command works"        [lindex [probe::last] 0] act_inner

probe::reset
eng2 dispatch "style"
check "included command works"           [lindex [probe::last] 0] act_outer

probe::reset
eng2 dispatch "layer"
check "second included command works"    [lindex [probe::last] 0] act_outer

eng2 destroy

# --- includes: state's own command overrides included ---

set override_graph {
    common {
        commands {
            h(ello) {action act_outer help "from include"}
        }
    }
    line {
        prompt "line> "
        includes {common}
        commands {
            h(ello) {action act_inner help "from state"}
        }
    }
}
cmdgraph::Engine create eng3 $override_graph line
probe::reset
eng3 dispatch "hello"
check "state's command overrides included" [lindex [probe::last] 0] act_inner
eng3 destroy

# --- includes: unknown include rejected ---

set bad_include {
    s {
        prompt "> "
        includes {missing}
        commands {}
    }
}
set ok [catch {cmdgraph::Engine create bad $bad_include s} err]
check "unknown include rejected"        $ok 1

# --- context & on_enter ---

# Action that reads context and returns it via probe
proc act_read_ctx {args} { probe::record act_read_ctx [cmdgraph::context] }

# Action that returns context for do_goto (the "select <id>" pattern)
proc act_select {args} {
    if {[llength $args] != 1} { return "" }
    probe::record act_select [lindex $args 0]
    return [lindex $args 0]
}

# on_enter that records the context it sees
proc enter_detail {} { probe::record enter_detail [cmdgraph::context] }

set ctx_graph {
    home {
        prompt "> "
        commands {
            s(elect) {do_goto detail act_select help "Select <id>"}
            g(o)     {goto    detail            help "Goto with no context"}
            q(uit)   {quit                      help "Exit"}
        }
    }
    detail {
        prompt   "detail> "
        on_enter enter_detail
        commands {
            w(ho)  {action act_read_ctx help "Show current context"}
            b(ack) {pop                 help "Back"}
        }
    }
}

cmdgraph::Engine create ec $ctx_graph home

# --- root has empty context ---

check "root context is empty"        [ec current_context] ""

# --- do_goto with non-empty result becomes context ---

probe::reset
ec dispatch "select 42"
check "do_goto with arg transitions"     [ec current_state]   detail
check "context set from action return"   [ec current_context] 42

# --- on_enter fires and sees the new context ---

set on_enter_call ""
foreach h [probe::all] {
    if {[lindex $h 0] eq "enter_detail"} { set on_enter_call $h }
}
check "on_enter fired after do_goto"     [lindex $on_enter_call 0] enter_detail
check "on_enter sees new context"        [lindex $on_enter_call 1] 42

# --- action reads context via cmdgraph::context ---

probe::reset
ec dispatch "who"
check "action reads current context"     [lindex [probe::last] 1] 42

# --- pop restores previous context ---

ec dispatch "back"
check "pop returns to root"              [ec current_state]   home
check "pop restores empty context"       [ec current_context] ""

# --- goto pushes with empty context ---

probe::reset
ec dispatch "go"
check "goto pushed state"                [ec current_state]   detail
check "goto pushes empty context"        [ec current_context] ""

# on_enter should still fire for goto, with empty context
set on_enter_call ""
foreach h [probe::all] {
    if {[lindex $h 0] eq "enter_detail"} { set on_enter_call $h }
}
check "on_enter fires after goto"        [lindex $on_enter_call 0] enter_detail
check "on_enter sees empty ctx for goto" [lindex $on_enter_call 1] ""

ec dispatch "back"

# --- do_goto with empty return: no transition, no on_enter ---

probe::reset
ec dispatch "select"
check "do_goto fail stays in state"      [ec current_state]   home

set fired 0
foreach h [probe::all] {
    if {[lindex $h 0] eq "enter_detail"} { set fired 1 }
}
check "on_enter does not fire on fail"   $fired 0

# --- do_goto with literal "0" return: transitions with ctx "0" (parity rule) ---
# Regression for boolean-coercion bug: "0", "no", "false" are non-empty
# strings, so they must be treated as valid contexts and transition.

probe::reset
ec dispatch "select 0"
check "do_goto with '0' transitions"     [ec current_state]   detail
check "context set to '0' literal"       [ec current_context] 0

set on_enter_call ""
foreach h [probe::all] {
    if {[lindex $h 0] eq "enter_detail"} { set on_enter_call $h }
}
check "on_enter sees '0' context"        [lindex $on_enter_call 1] 0
ec dispatch "back"

# --- cmdgraph::context returns "" outside dispatch ---

check "context is empty outside action"  [cmdgraph::context] ""

ec destroy

# --- nested dispatch preserves the outer context (B1) ---
#
# A GUI back-end (or any caller) may re-enter the engine from inside an
# action. The outer action's cmdgraph::context must survive that — the
# old code unconditionally reset current_context to "" after invoke,
# which wiped the outer save.

set nested_ctx_before ""
set nested_ctx_after  ""

# Inner action just reads its own context, lets the engine reset it.
proc nest_inner_act {args} {
    return ""
}

# Outer action: read context, recurse via dispatch, read context again.
proc nest_outer_act {args} {
    global nested_ctx_before nested_ctx_after
    set nested_ctx_before [cmdgraph::context]
    nest_engine dispatch "inner"
    set nested_ctx_after  [cmdgraph::context]
    return ""
}

proc nest_open_act {args} { return [lindex $args 0] }

set nest_graph {
    root {
        prompt "root> "
        commands {
            o(pen) {do_goto child nest_open_act args {{id char}} help "open"}
            q(uit) {quit help "quit"}
        }
    }
    child {
        prompt "child> "
        commands {
            outer {action nest_outer_act help "outer reads ctx, calls inner"}
            inner {action nest_inner_act help "inner reads its own ctx"}
            b(ack) {pop help "back"}
        }
    }
}

cmdgraph::Engine create nest_engine $nest_graph root
nest_engine dispatch "open BOOK42"
nest_engine dispatch "outer"
check "nested dispatch: outer ctx before inner"  $nested_ctx_before BOOK42
check "nested dispatch: outer ctx after inner"   $nested_ctx_after  BOOK42
nest_engine destroy

# Same scenario via on_enter (which also restores). Push a child whose
# on_enter triggers a nested dispatch; the on_enter must see its own
# context, and the outer action's view must be unaffected.

set on_enter_saw ""
set outer_saw_before ""
set outer_saw_after  ""

proc nest_inner_act2 {args} {
    return ""
}

proc nest_on_enter_grandchild {} {
    global on_enter_saw
    set on_enter_saw [cmdgraph::context]
    # Re-enter the engine from inside on_enter.
    nest_engine2 dispatch "inner"
}

proc nest_outer_act2 {args} {
    global outer_saw_before outer_saw_after
    set outer_saw_before [cmdgraph::context]
    # Pushing grandchild fires its on_enter, which dispatches a nested cmd.
    nest_engine2 dispatch "descend SUB"
    set outer_saw_after [cmdgraph::context]
    # Unwind so the outer caller is back where it was.
    nest_engine2 dispatch "back"
    return ""
}

proc nest_open_act2    {args} { return [lindex $args 0] }
proc nest_descend_act2 {args} { return [lindex $args 0] }

set nest_graph2 {
    root {
        prompt "root> "
        commands {
            o(pen) {do_goto child nest_open_act2 args {{id char}} help "open"}
            q(uit) {quit help "quit"}
        }
    }
    child {
        prompt "child> "
        commands {
            outer   {action nest_outer_act2 help "outer"}
            descend {do_goto grandchild nest_descend_act2 args {{id char}} help "descend"}
            inner   {action nest_inner_act2 help "inner"}
            b(ack)  {pop help "back"}
        }
    }
    grandchild {
        prompt "gc> "
        on_enter nest_on_enter_grandchild
        commands {
            inner  {action nest_inner_act2 help "inner"}
            b(ack) {pop help "back"}
        }
    }
}

cmdgraph::Engine create nest_engine2 $nest_graph2 root
nest_engine2 dispatch "open BOOK99"
nest_engine2 dispatch "outer"
check "nested on_enter: outer ctx survives"      $outer_saw_after  BOOK99
check "nested on_enter: on_enter saw new ctx"    $on_enter_saw     SUB
check "nested on_enter: outer ctx before push"   $outer_saw_before BOOK99
nest_engine2 destroy

# --- dispatch return codes ---

proc noop_action  {args} { return }
proc throw_action {args} { error "boom" }
proc ok_gate      {args} { return "go" }
proc no_gate      {args} { return "" }

set rc_graph {
    home {
        prompt "> "
        commands {
            a(ction) {action  noop_action  help "ok"}
            ae(rror) {action  throw_action help "action errors"}
            g(o)     {goto    other        help "transitioned"}
            t(ry)    {do_goto other ok_gate      help "do_goto returns non-empty"}
            f(ail)   {do_goto other no_gate      help "do_goto returns empty"}
            e(rror)  {do_goto other throw_action help "do_goto errors"}
            s(ave)   {action  noop_action  help "save"}
            s(ub)    {action  noop_action  help "sub"}
            p(op)    {pop                  help "pop from root"}
            q(uit)   {quit                 help "quit"}
        }
    }
    other {
        prompt "other> "
        commands {
            b(ack) {pop help "back"}
        }
    }
}

cmdgraph::Engine create er $rc_graph home

check "dispatch ambiguous returns ambiguous"  [er dispatch "s"]        ambiguous
check "dispatch unknown returns unknown"      [er dispatch "nonesuch"] unknown
check "dispatch action returns ok"            [er dispatch "action"]   ok
check "dispatch action error returns error"   [er dispatch "aerror"]   error
check "dispatch do_goto fail returns ok"      [er dispatch "fail"]     ok
check "dispatch do_goto error returns error"  [er dispatch "error"]    error
check "dispatch empty line returns ok"        [er dispatch ""]         ok
check "dispatch blank line returns ok"        [er dispatch "   "]      ok
check "dispatch built-in help returns ok"     [er dispatch "help"]     ok
check "dispatch built-in ? returns ok"        [er dispatch "?"]        ok
check "dispatch goto returns transitioned"    [er dispatch "go"]       transitioned
check "dispatch pop returns transitioned"     [er dispatch "back"]     transitioned
check "dispatch do_goto ok returns transitioned" [er dispatch "try"]   transitioned
er dispatch "back"
check "dispatch quit returns exited"          [er dispatch "quit"]     exited
check "dispatch on dead engine returns exited" [er dispatch "action"]  exited
er destroy

# Pop from root state must also yield `exited`
cmdgraph::Engine create er2 $rc_graph home
check "dispatch pop from root returns exited" [er2 dispatch "pop"]     exited
er2 destroy

# --- run_file ---

cmdgraph::Engine create ef $ctx_graph home

# Missing file: ok=0, stat=open, state unchanged
set miss [ef run_file "/nonexistent/cmdgraph_no_such_file"]
check "run_file missing-file ok=0"   [dict get $miss ok] 0
check "run_file missing-file stat"   [dict get $miss stat] open
check "run_file missing-file line 0" [dict get $miss line] 0
check "run_file missing-file leaves state" [ef current_state] home

# Script with a comment, a blank line, then select/who/back — ends back at home
set script_path "/tmp/cmdgraph_test_[pid].txt"
set fh [open $script_path w]
puts $fh "# a comment line"
puts $fh ""
puts $fh "   "
puts $fh "select 99"
puts $fh "who"
puts $fh "back"
close $fh

probe::reset
set rc [ef run_file $script_path]
check "run_file success ok=1"            [dict get $rc ok] 1
check "run_file success stat clean"      [dict get $rc stat] ""
check "run_file success line 0"          [dict get $rc line] 0
check "run_file returns to home"         [ef current_state] home

# Verify the script dispatched the right actions with the right args
set sel_arg ""
set who_ctx ""
foreach h [probe::all] {
    switch [lindex $h 0] {
        act_select    { set sel_arg [lindex $h 1] }
        act_read_ctx  { set who_ctx [lindex $h 1] }
    }
}
check "run_file dispatched select arg"   $sel_arg 99
check "run_file dispatched who saw ctx"  $who_ctx 99

# Comments and blanks are skipped: only select/who/back ran — three probe entries
# (act_select, enter_detail from on_enter, act_read_ctx). If blanks/comments had
# been dispatched, we'd see "unknown:" output and extra entries.
set dispatched_actions [lmap h [probe::all] {lindex $h 0}]
check "run_file probe history" $dispatched_actions {act_select enter_detail act_read_ctx}

file delete $script_path
ef destroy

# Stops at engine exit: lines after `quit` must not run
cmdgraph::Engine create ef2 $ctx_graph home
set script_q "/tmp/cmdgraph_test_quit_[pid].txt"
set fh [open $script_q w]
puts $fh "quit"
puts $fh "select 99"
close $fh

probe::reset
ef2 run_file $script_q
check "run_file stops at engine exit"    [ef2 is_running] 0

set tried_select 0
foreach h [probe::all] {
    if {[lindex $h 0] eq "act_select"} { set tried_select 1 }
}
check "run_file did not run after quit"  $tried_select 0

file delete $script_q
ef2 destroy

# run_file stops at the first failing line and reports stat/errmsg/line
cmdgraph::Engine create ef3 $ctx_graph home
set script_bad "/tmp/cmdgraph_test_bad_[pid].txt"
set fh [open $script_bad w]
puts $fh "# header"
puts $fh "select 7"
puts $fh "back"
puts $fh "nosuchcmd here"
puts $fh "select 8"
close $fh
ef3 set_io_channels stdin "" ""
probe::reset
set br [ef3 run_file $script_bad]
check "run_file bad ok=0"          [dict get $br ok] 0
check "run_file bad stat"          [dict get $br stat] unknown
check "run_file bad line number"   [dict get $br line] 4
check "run_file bad errmsg"        [dict get $br errmsg] "unknown: nosuchcmd"
set ran [lmap h [probe::all] {lindex $h 0}]
check "run_file stopped before line 5" [expr {"act_select" in $ran && [llength [lsearch -all -exact $ran act_select]] == 1}] 1
file delete $script_bad
ef3 destroy

# --- reset rewinds runtime state without rebuilding ---

cmdgraph::Engine create er $ctx_graph home
er set_io_channels stdin "" ""
er dispatch {select "x}
check "reset: error recorded"     [expr {[er last_error] ne ""}] 1
er dispatch "select 42"
check "reset: pushed before"      [er current_state] detail
er reset
check "reset: back at initial"    [er current_state] home
check "reset: context cleared"    [er current_context] ""
check "reset: last_error cleared" [er last_error] ""
check "reset: still running"      [er is_running] 1
er dispatch "quit"
check "reset: revives after quit" [er is_running] 0
er reset
check "reset: running after quit-reset" [er is_running] 1
check "reset: state after quit-reset"   [er current_state] home
er destroy

# --- configurable output and diagnostics ---

cmdgraph::Engine create ed $graph outer
ed set_io_channels stdin "" ""

check "quiet unknown returns unknown" [ed dispatch "nonesuch"] unknown
check "quiet unknown records last_message" [ed last_message] "unknown: nonesuch"

probe::reset
check "quiet unmatched quote returns error" [ed dispatch {action "unterminated}] error
check "quiet unmatched quote records last_error" [ed last_error] "unmatched quote in arguments"
check "quiet unmatched quote not dispatched" [probe::count] 0

ed destroy

cmdgraph::Engine create ed2 $ctx_graph home
ed2 set_io_channels stdin "" ""
set script_quiet "/tmp/cmdgraph_test_quiet_[pid].txt"
set fh [open $script_quiet w]
puts $fh "select 101"
puts $fh "back"
close $fh

probe::reset
check "run_file quiet echo false succeeds" [dict get [ed2 run_file $script_quiet 0] ok] 1
check "run_file quiet echo false dispatched" [lindex [probe::last] 0] enter_detail
file delete $script_quiet
ed2 destroy

# --- input channel: run reads from a configured non-stdin channel ---

cmdgraph::Engine create ed3 $ctx_graph home
set script_in "/tmp/cmdgraph_test_input_[pid].txt"
set fh [open $script_in w]
puts $fh "select 77"
puts $fh "back"
puts $fh "quit"
close $fh
set ich [open $script_in r]
ed3 set_io_channels $ich "" ""
probe::reset
ed3 run
close $ich
set saw_ctx ""
foreach h [probe::all] {
    if {[lindex $h 0] eq "enter_detail"} { set saw_ctx [lindex $h 1] }
}
check "run reads from configured input channel" $saw_ctx 77
check "run from channel exits on quit"          [ed3 is_running] 0
file delete $script_in
ed3 destroy

# --- DAG validation: goto/do_goto edges between concrete states must not cycle ---

proc check_cycle {label graph initial must_contain} {
    global pass fail
    set ok [catch {cmdgraph::Engine create cyc_eng $graph $initial} err]
    if {$ok != 1} {
        puts "FAIL: $label (expected error, construction succeeded)"
        incr fail
        cyc_eng destroy
        return
    }
    if {[string first "cycle detected" $err] < 0} {
        puts "FAIL: $label (msg missing 'cycle detected': '$err')"
        incr fail
        return
    }
    if {[string first $must_contain $err] < 0} {
        puts "FAIL: $label (msg missing '$must_contain': '$err')"
        incr fail
        return
    }
    puts "PASS: $label — $err"
    incr pass
}

# self-loop via goto
check_cycle "self-loop via goto" {
    a { prompt "a> " commands { loop {goto a} } }
} a "a -> a"

# self-loop via do_goto
check_cycle "self-loop via do_goto" {
    a { prompt "a> " commands { loop {do_goto a gate_ok} } }
} a "a -> a"

# two-cycle
check_cycle "two-cycle a->b->a" {
    a { prompt "a> " commands { go {goto b} } }
    b { prompt "b> " commands { go {goto a} } }
} a "a -> b -> a"

# three-cycle, mixed edge kinds
check_cycle "three-cycle a->b->c->a" {
    a { prompt "a> " commands { go {goto b} } }
    b { prompt "b> " commands { go {do_goto c gate_ok} } }
    c { prompt "c> " commands { go {goto a} } }
} a "a -> b -> c -> a"

# valid tree-shaped DAG accepted
set dag_graph {
    root  { prompt "r> "  commands { l {goto left}  r {goto right} } }
    left  { prompt "l> "  commands { x {goto leaf}  b {pop} } }
    right { prompt "rt> " commands { x {goto leaf}  b {pop} } }
    leaf  { prompt "lf> " commands { b {pop} } }
}
set ok [catch {cmdgraph::Engine create dag_eng $dag_graph root} err]
check "tree-shaped DAG accepted" $ok 0
if {$ok == 0} { dag_eng destroy }

# pop is the return path, not a cycle edge
set pop_graph {
    a { prompt "a> " commands { d {goto b} } }
    b { prompt "b> " commands { u {pop} } }
}
set ok [catch {cmdgraph::Engine create pop_eng $pop_graph a} err]
check "pop is not a cycle edge" $ok 0
if {$ok == 0} { pop_eng destroy }

# swap/do_swap replace the top frame (pop-then-push) so a mutually-swapping
# a<->b pair is inherently cyclic yet valid — exempt from the DAG check.
set swap_dag_graph {
    a { prompt "a> " commands { n {swap b} } }
    b { prompt "b> " commands { p {do_swap a gate_ok} } }
}
set ok [catch {cmdgraph::Engine create swap_dag_eng $swap_dag_graph a} err]
check "swap/do_swap are not cycle edges" $ok 0
if {$ok == 0} { swap_dag_eng destroy }

# cycle involving an include — the include itself is just command mix-in, but
# if it contributes a goto that closes a cycle between concrete states, that
# IS a cycle and should be reported.
check_cycle "cycle via included command" {
    nav    { commands { to_a {goto a} } }
    a      { prompt "a> " commands { to_b {goto b} } }
    b      { prompt "b> " includes {nav} commands {} }
} a "a -> b -> a"

# --- construction-time edge validation (proc/target slots required) ---
# Parity contract (canonical wording — matches Fortran die_missing and
# C++ add_command throw):
#   cmdgraph: <kind> edge '<spec>' missing required <proc|target>

proc check_missing {label graph initial expected} {
    global pass fail
    set ok [catch {cmdgraph::Engine create mr_eng $graph $initial} err]
    if {$ok != 1} {
        puts "FAIL: $label (expected error, construction succeeded)"
        incr fail
        mr_eng destroy
        return
    }
    if {$err ne $expected} {
        puts "FAIL: $label\n  expected: $expected\n  actual:   $err"
        incr fail
        return
    }
    puts "PASS: $label"
    incr pass
}

check_missing "action edge missing proc" {
    r { prompt "r> " commands { a(ct) {action} } }
} r "cmdgraph: action edge 'a(ct)' missing required proc"

check_missing "goto edge missing target" {
    r { prompt "r> " commands { g(o) {goto} } }
} r "cmdgraph: goto edge 'g(o)' missing required target"

check_missing "do_goto edge missing target" {
    r { prompt "r> " commands { t(ry) {do_goto "" act_outer} } }
} r "cmdgraph: do_goto edge 't(ry)' missing required target"

check_missing "do_goto edge missing proc" {
    r { prompt "r> " commands { t(ry) {do_goto dest ""} }
        }
    dest { prompt "d> " commands { b(ack) {pop} } }
} r "cmdgraph: do_goto edge 't(ry)' missing required proc"

check_missing "do_pop edge missing proc" {
    r { prompt "r> " commands { c(ommit) {do_pop} } }
} r "cmdgraph: do_pop edge 'c(ommit)' missing required proc"

check_missing "swap edge missing target" {
    r { prompt "r> " commands { n(ext) {swap} } }
} r "cmdgraph: swap edge 'n(ext)' missing required target"

check_missing "do_swap edge missing target" {
    r { prompt "r> " commands { p(ick) {do_swap "" act_outer} } }
} r "cmdgraph: do_swap edge 'p(ick)' missing required target"

check_missing "do_swap edge missing proc" {
    r { prompt "r> " commands { p(ick) {do_swap dest ""} }
        }
    dest { prompt "d> " commands { b(ack) {pop} } }
} r "cmdgraph: do_swap edge 'p(ick)' missing required proc"

# --- do_pop: invoke proc then pop on success ---

set commit_called 0
proc act_commit {args} {
    global commit_called
    incr commit_called
    return 1
}
proc act_commit_fail {args} { error "deliberate" }

set dp_graph {
    home   { prompt "home> "   commands { s(elect) {goto detail}  q(uit) {quit} } }
    detail { prompt "detail> " commands {
        c(ommit) {do_pop act_commit       help "commit and pop"}
        bad      {do_pop act_commit_fail  help "errors, no pop"}
        e(sc)    {pop                     help "abort"}
    } }
}
cmdgraph::Engine create dp_eng $dp_graph home

# push into detail, then do_pop returns to home
check "do_pop: pushed into detail"   [dp_eng dispatch "select"]    transitioned
check "do_pop: in detail"            [dp_eng current_state]        detail
check "do_pop: commit transitions"   [dp_eng dispatch "commit"]    transitioned
check "do_pop: returned to home"     [dp_eng current_state]        home
check "do_pop: action ran"           $commit_called                 1

# do_pop with a Tcl error in action: stays put, returns 'error'
check "do_pop: re-enter detail"      [dp_eng dispatch "select"]    transitioned
check "do_pop: bad errors"           [dp_eng dispatch "bad"]       error
check "do_pop: still in detail"      [dp_eng current_state]        detail
check "do_pop: action_call count"    $commit_called                 1

# plain pop (esc) is the abort path
check "do_pop: esc pops"             [dp_eng dispatch "esc"]       transitioned
check "do_pop: back in home"         [dp_eng current_state]        home

dp_eng destroy

# --- swap / do_swap: replace the top frame (pop-then-push) ---

proc enter_swap_a {} { probe::record enter_swap_a [cmdgraph::context] }
proc enter_swap_b {} { probe::record enter_swap_b [cmdgraph::context] }

set swap_graph {
    root  { prompt "r> " commands { g(o) {goto toola}  q(uit) {quit} } }
    toola {
        prompt   "a> "
        on_enter enter_swap_a
        commands { n(ext) {swap toolb}  b(ack) {pop} }
    }
    toolb {
        prompt   "b> "
        on_enter enter_swap_b
        commands {
            p(ick) {do_swap toola act_select help "swap back with ctx"}
            v(eto) {do_swap toola gate_no    help "empty return stays"}
            e(rr)  {do_swap toola act_throw  help "error stays"}
            b(ack) {pop}
        }
    }
}
cmdgraph::Engine create sw_eng $swap_graph root

# go pushes toola; next swaps (replace) to toolb
check "swap: go to toola"            [sw_eng dispatch "go"]     transitioned
check "swap: in toola"               [sw_eng current_state]     toola
probe::reset
check "swap: next swaps to toolb"    [sw_eng dispatch "next"]   transitioned
check "swap: in toolb"               [sw_eng current_state]     toolb
check "swap: empties context"        [sw_eng current_context]   ""
check "swap: on_enter toolb fired"   [lindex [probe::last] 0]   enter_swap_b

# do_swap error stays; empty-return stays
check "do_swap: error stays"         [sw_eng dispatch "err"]    error
check "do_swap: still in toolb"      [sw_eng current_state]     toolb
check "do_swap: empty stays"         [sw_eng dispatch "veto"]   ok
check "do_swap: still in toolb (2)"  [sw_eng current_state]     toolb

# do_swap non-empty return swaps back to toola with the returned context
probe::reset
check "do_swap: pick transitions"    [sw_eng dispatch "pick 7"] transitioned
check "do_swap: in toola"            [sw_eng current_state]     toola
check "do_swap: context is 7"        [sw_eng current_context]   7
check "do_swap: on_enter toola ctx"  [probe::last]              {enter_swap_a 7}

# replace-not-push: a single back from toola returns to root
check "swap: back to root"           [sw_eng dispatch "back"]   transitioned
check "swap: in root"                [sw_eng current_state]     root

sw_eng destroy

# --- declarative argument validation ---

proc typed_select {args} {
    probe::record typed_select $args
    return [lindex $args 0]
}
proc typed_real {args} {
    probe::record typed_real $args
}
proc typed_word {args} {
    probe::record typed_word $args
}
proc typed_pair {args} {
    probe::record typed_pair $args
}

set arg_graph {
    home {
        prompt "> "
        commands {
            s(elect) {do_goto detail typed_select args {{id int}} help "Select <id>"}
            r(eal)   {action typed_real args {{x real}} help "Capture real"}
            w(ord)   {action typed_word args {{name char}} help "Capture word"}
            p(air)   {action typed_pair args {{id int} {label char optional}} help "Optional label"}
            q(uit)   {quit help "Exit"}
        }
    }
    detail {
        prompt "detail> "
        commands {
            b(ack) {pop help "Back"}
        }
    }
}

cmdgraph::Engine create arg_eng $arg_graph home

probe::reset
check "arg spec int accepts integer"       [arg_eng dispatch "select 42"] transitioned
check "arg spec int invoked action"        [lindex [probe::last] 0] typed_select
check "arg spec int set context"           [arg_eng current_context] 42
arg_eng dispatch "back"

probe::reset
check "arg spec int rejects real"          [arg_eng dispatch "select 4.2"] error
check "arg spec int mismatch not invoked"  [probe::count] 0
check "arg spec int mismatch stays"        [arg_eng current_state] home

probe::reset
check "arg spec detects missing required"  [arg_eng dispatch "select"] error
check "arg spec missing not invoked"       [probe::count] 0

probe::reset
check "arg spec detects extra argument"    [arg_eng dispatch "select 42 extra"] error
check "arg spec extra not invoked"         [probe::count] 0

probe::reset
check "arg spec real accepts d exponent"   [arg_eng dispatch "real -1.25d2"] ok
check "arg spec real passes original text" [lindex [probe::last] 1] -1.25d2

probe::reset
# Int → real promotion: an integer literal in a real slot is accepted; the
# action receives the raw token (Tcl is dynamically typed). Parity with
# C++ ARG_REAL int-variant promotion and Fortran post-validate normalisation.
check "arg spec real accepts int token"    [arg_eng dispatch "real 7"] ok
check "arg spec real int-promoted invoked" [probe::count] 1
check "arg spec real int-promoted value"   [lindex [probe::last] 1] 7

probe::reset
check "arg spec char accepts nonnumeric"   [arg_eng dispatch "word /tmp/path"] ok
check "arg spec char passes word"          [lindex [probe::last] 1] /tmp/path

probe::reset
check "arg spec char accepts quoted words" [arg_eng dispatch {word "two words"}] ok
check "arg spec char strips quotes"        [lindex [probe::last] 1] {{two words}}

probe::reset
check "arg spec char accepts quoted empty" [arg_eng dispatch {word ""}] ok
check "arg spec char empty value"          [lindex [probe::last] 1] {{}}

probe::reset
check "arg spec detects unmatched quote"   [arg_eng dispatch {word "two words}] error
check "arg spec unmatched not invoked"     [probe::count] 0

probe::reset
check "arg spec char rejects numeric token" [arg_eng dispatch "word 12"] error
check "arg spec char mismatch not invoked" [probe::count] 0

probe::reset
check "arg spec optional may be omitted"   [arg_eng dispatch "pair 5"] ok
check "arg spec optional omitted args"     [lindex [probe::last] 1] 5

probe::reset
check "arg spec optional may be present"   [arg_eng dispatch "pair 5 label"] ok
check "arg spec optional present args"     [lindex [probe::last] 1] {5 label}

arg_eng destroy

# --- introspection: available_commands / state_path ---

cmdgraph::Engine create intr_eng $arg_graph home

set cmds [intr_eng available_commands]
check "available_commands count in home"   [llength $cmds] 5
check "available_commands is deterministic" [intr_eng available_commands] $cmds

proc find_cmd {cmds spec} {
    foreach c $cmds { if {[dict get $c spec] eq $spec} { return $c } }
    return ""
}
set sel [find_cmd $cmds "s(elect)"]
check "command_info spec"   [dict get $sel spec]   "s(elect)"
check "command_info req"    [dict get $sel req]    "s"
check "command_info opt"    [dict get $sel opt]    "elect"
check "command_info kind"   [dict get $sel kind]   do_goto
check "command_info target" [dict get $sel target] detail
check "command_info help"   [dict get $sel help]   "Select <id>"
check "command_info args len"  [llength [dict get $sel args]] 1
check "command_info args kind" [dict get [lindex [dict get $sel args] 0] kind] int
set q [find_cmd $cmds "q(uit)"]
check "command_info quit kind"   [dict get $q kind]   quit
check "command_info quit target" [dict get $q target] ""

check "state_path at root" [intr_eng state_path] home

probe::reset
intr_eng dispatch "select 7"
check "state_path after do_goto"      [intr_eng state_path] {home detail}
set dcmds [intr_eng available_commands]
check "available_commands in detail"  [llength $dcmds] 1
check "detail command is pop"         [dict get [lindex $dcmds 0] kind] pop

intr_eng dispatch "back"
check "state_path after pop"          [intr_eng state_path] home

intr_eng dispatch "quit"
check "available_commands empty when stopped" [intr_eng available_commands] {}
check "state_path empty when stopped"         [intr_eng state_path] {}
intr_eng destroy

# --- help/usage generation from arg specs ---

cmdgraph::Engine create help_eng $arg_graph home
set help_out "/tmp/cmdgraph_test_help_[pid].txt"
set hfh [open $help_out w]
help_eng set_io_channels stdin $hfh ""
help_eng dispatch "help"
close $hfh
set hfh [open $help_out r]
set help_text [read $hfh]
close $hfh
file delete $help_out
help_eng destroy

proc help_has {text needle} {
    return [expr {[string first $needle $text] >= 0}]
}
proc help_line {text spec} {
    foreach ln [split $text \n] {
        if {[string first $spec $ln] >= 0} { return $ln }
    }
    return ""
}

check "usage: required int arg"     [help_has $help_text {s(elect) <id:int>}] 1
check "usage: required real arg"    [help_has $help_text {r(eal) <x:real>}] 1
check "usage: required char arg"    [help_has $help_text {w(ord) <name:char>}] 1
check "usage: required + optional"  [help_has $help_text {p(air) <id:int> [label:char]}] 1
set qline [help_line $help_text {q(uit)}]
check "usage: no-arg command plain" \
    [expr {![string match {*<*} $qline] && ![string match {*\[*} $qline]}] 1
check "usage: help text preserved"  [help_has $help_text {Select <id>}] 1

set bad_arg_graph {
    home {
        prompt "> "
        commands {
            x {action typed_word args {{thing blob}}}
        }
    }
}
set ok [catch {cmdgraph::Engine create bad_args $bad_arg_graph home} err]
check "bad arg kind rejected" $ok 1

# --- rest-of-line argument kind ---

set rest_graph {
    home {
        prompt "> "
        commands {
            e(cho) {action act_outer args {{text rest}}                  help "Echo rest"}
            n(ote) {action act_outer args {{id int} {body rest}}         help "Note id + body"}
            o(pt)  {action act_outer args {{id int} {body rest optional}} help "Optional rest"}
            t(ag)  {action act_outer args {{label char} {body rest}}     help "Tag + body"}
            q(uit) {quit help "Exit"}
        }
    }
}
cmdgraph::Engine create rest_eng $rest_graph home

proc rest_args {} { return [lindex [probe::last] 1] }

probe::reset
check "rest: verbatim multiword"      [rest_eng dispatch "echo hello big world"] ok
check "rest: captured verbatim"       [lindex [rest_args] 0] "hello big world"

probe::reset
check "rest: strips leading run, keeps internal" \
                                      [rest_eng dispatch "echo   a  b "] ok
check "rest: internal+trailing kept"  [lindex [rest_args] 0] "a  b "

probe::reset
check "rest: leading int then rest"   [rest_eng dispatch "note 5 buy milk and eggs"] ok
check "rest: lead int parsed"         [lindex [rest_args] 0] 5
check "rest: body verbatim"           [lindex [rest_args] 1] "buy milk and eggs"

probe::reset
check "rest: optional omitted ok"     [rest_eng dispatch "opt 9"] ok
check "rest: optional omitted arity"  [llength [rest_args]] 1
check "rest: optional omitted id"     [lindex [rest_args] 0] 9

probe::reset
check "rest: optional present ok"     [rest_eng dispatch "opt 9 hello there"] ok
check "rest: optional present body"   [lindex [rest_args] 1] "hello there"

probe::reset
check "rest: embedded quotes kept"    [rest_eng dispatch {echo he said "hi"}] ok
check "rest: quotes not stripped"     [lindex [rest_args] 0] {he said "hi"}

probe::reset
check "rest: lone quote allowed"      [rest_eng dispatch {echo a " b}] ok
check "rest: lone quote verbatim"     [lindex [rest_args] 0] {a " b}

probe::reset
check "rest: missing required body"   [rest_eng dispatch "note 5"] error
check "rest: missing not invoked"     [probe::count] 0

probe::reset
check "rest: lead quote still checked" [rest_eng dispatch {tag "unterminated body}] error
check "rest: lead quote not invoked"  [probe::count] 0

rest_eng destroy

set rest_not_last {
    home {
        prompt "> "
        commands {
            x {action act_outer args {{body rest} {id int}}}
        }
    }
}
set ok [catch {cmdgraph::Engine create bad_rest $rest_not_last home} err]
check "rest must be last rejected"    $ok 1

cmdgraph::Engine create rusage_eng $rest_graph home
set ru "/tmp/cmdgraph_test_rusage_[pid].txt"
set rfh [open $ru w]
rusage_eng set_io_channels stdin $rfh ""
rusage_eng dispatch "help"
close $rfh
set rfh [open $ru r]
set rusage_text [read $rfh]
close $rfh
file delete $ru
rusage_eng destroy
check "rest: help renders required"   [help_has $rusage_text {e(cho) <text:rest>}] 1
check "rest: help renders optional"   [help_has $rusage_text {o(pt) <id:int> [body:rest]}] 1

# --- array arg spec helpers ---

set raw_i3 [cmdgraph::arg_int_n x 3]
check "arg_int_n: count"       [llength $raw_i3]    3
check "arg_int_n: \[0\] name"  [lindex $raw_i3 0 0] x
check "arg_int_n: \[0\] kind"  [lindex $raw_i3 0 1] int
check "arg_int_n: \[2\] name"  [lindex $raw_i3 2 0] x

set raw_r2 [cmdgraph::arg_real_n pt 2]
check "arg_real_n: count"      [llength $raw_r2]    2
check "arg_real_n: \[0\] name" [lindex $raw_r2 0 0] pt
check "arg_real_n: \[0\] kind" [lindex $raw_r2 0 1] real
check "arg_real_n: \[1\] name" [lindex $raw_r2 1 0] pt

set raw_mixed [concat {{label char}} [cmdgraph::arg_real_n pt 2]]
check "concat mixed: count"    [llength $raw_mixed]    3
check "concat mixed: \[0\] kind" [lindex $raw_mixed 0 1] char
check "concat mixed: \[1\] kind" [lindex $raw_mixed 1 1] real
check "concat mixed: \[2\] kind" [lindex $raw_mixed 2 1] real

set array_graph [dict create \
    home [dict create \
        prompt "> " \
        commands [dict create \
            "p(oint)" [list action act_outer args [cmdgraph::arg_real_n pt 2] help "2D point"] \
            "i(nt3)"  [list action act_outer args [cmdgraph::arg_int_n n 3]   help "Three ints"] \
            "q(uit)"  {quit help Exit} \
        ] \
    ] \
]
cmdgraph::Engine create arr_eng $array_graph home
arr_eng set_io_channels stdin "" ""

probe::reset
check "real\[2\]: exact count ok"  [arr_eng dispatch "p 1.0 2.0"]    ok
check "real\[2\]: action invoked"  [lindex [probe::last] 0]          act_outer
check "real\[2\]: too few"         [arr_eng dispatch "p 1.0"]         error
check "real\[2\]: too many"        [arr_eng dispatch "p 1.0 2.0 3.0"] error
check "real\[2\]: wrong type"      [arr_eng dispatch "p 1.0 foo"]     error
check "int\[3\]: exact count ok"   [arr_eng dispatch "i 1 2 3"]       ok
check "int\[3\]: too few"          [arr_eng dispatch "i 1 2"]          error
check "int\[3\]: wrong type"       [arr_eng dispatch "i 1 2 3.5"]     error

set au "/tmp/cmdgraph_test_arr_[pid].txt"
set afh [open $au w]
arr_eng set_io_channels stdin $afh ""
arr_eng dispatch "help"
close $afh
set afh [open $au r]
set arr_text [read $afh]
close $afh
file delete $au
arr_eng destroy
check "array help: 2 real slots"   [help_has $arr_text {p(oint) <pt:real> <pt:real>}] 1
check "array help: 3 int slots"    [help_has $arr_text {i(nt3) <n:int> <n:int> <n:int>}] 1

# --- action errmsg via invoke dict ---

set errmsg_graph {
    home {
        prompt "> "
        commands {
            f(ail)   {action throw_action  help "throws with message"}
            n(oop)   {action noop_action   help "succeeds"}
            q(uit)   {quit                 help "exit"}
        }
    }
}
proc throw_action {args} { error "something went wrong" }
proc noop_action  {args} { }

cmdgraph::Engine create emsg_eng $errmsg_graph home
emsg_eng set_io_channels stdin "" ""

check "errmsg: action returns error"     [emsg_eng dispatch "fail"]  error
check "errmsg: last_error set"           [emsg_eng last_error]       "error: something went wrong"
check "errmsg: invoke errmsg key"        [dict get [emsg_eng invoke throw_action {}] errmsg] \
                                         "something went wrong"
check "errmsg: invoke errmsg empty ok"   [dict get [emsg_eng invoke noop_action {}] errmsg] ""

emsg_eng destroy

# --- version ---

set v [cmdgraph::version]
check "version major"  [dict get $v major]  1
check "version minor"  [dict get $v minor]  3
check "version patch"  [dict get $v patch]  0
check "version string" [dict get $v string] "1.3.0"

# --- Done ---

puts ""
puts "[expr {$pass+$fail}] tests: $pass passed, $fail failed"
