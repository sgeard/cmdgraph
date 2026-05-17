# kate: syntax Tcl/Tk;

# cmdgraph — state-graph driven command interpreter (written with Claude)
#
# A generic dispatch engine driven by a declarative graph of states and
# commands. The parsing logic is decoupled from the actions, so the same
# engine can drive any application by feeding it a different graph.
#
# Graph shape:
#   set graph {
#       state_name {
#           prompt   "prompt-string"
#           includes {other_state ...}     ;# optional — share command sets
#           on_enter proc_name             ;# optional — called when entered
#           commands {
#               s(pec)  { action  proc_name              [args {{id int} {name char optional}}] [help "..."] }
#               g(o)    { goto    state_name             [help "..."] }
#               t(ry)   { do_goto state_name proc_name   [help "..."] }
#               b(ack)  { pop                            [help "..."] }
#               q(uit)  { quit                           [help "..."] }
#           }
#       }
#       ...
#   }
#
# Context (object association):
#   A state can carry an opaque "context" — typically the object the state
#   operates on (an account id, a filename, etc.). The context is supplied
#   by the do_goto action's return value:
#       - return "" or boolean-false (0, false, no, off) → no transition
#       - return any other value → transition; the value becomes the context
#   Action procs read the current context with `cmdgraph::context` (or via
#   `[$engine current_context]` when multiple engines are in play). A `goto`
#   edge pushes with empty context; `pop` returns to the previous (state, ctx).
#
# on_enter hook:
#   When a state is pushed (goto or successful do_goto), if it defines
#   `on_enter proc_name`, that proc is called. The new state's context is
#   visible via cmdgraph::context. on_enter is purely side-effecting — its
#   return value is ignored.
#
# Abstract states:
#   A state without a `prompt` cannot be entered. It exists only to hold a
#   command set that other states reference via `includes`. Useful for
#   sharing common commands across many states (e.g. "set style" available
#   from every drawing-primitive state).
#
# Include semantics:
#   - State's own commands take precedence over included ones.
#   - When multiple includes have the same command, later includes win.
#   - Includes are flat — they do not transitively pull in includes-of-includes.
#
# Edge kinds:
#   action  proc_name              — invoke proc, ignore return value, stay
#   goto    state_name             — push state, no proc call
#   do_goto state_name proc_name   — invoke proc; if it returns a truthy
#                                    value (1, true, yes, on) push the
#                                    target state, otherwise stay
#   pop                            — pop the state stack (e.g. "esc"/"back")
#   do_pop  proc_name              — invoke proc, then pop on success (the
#                                    commit-and-return pattern); a Tcl
#                                    error in the proc leaves the stack
#                                    alone
#   quit                           — exit the engine
#
# Action contract:
#   - Action procs take {args} (variadic), parse their own arguments.
#   - A command may declare `args {{name int|real|char ?optional?} ...}`.
#     When present, the engine validates argument count and token types before
#     invoking the action. Only trailing positions may be omitted.
#   - For do_goto, the proc must return a Tcl boolean: 1/true/yes/on for
#     success (triggering the transition), anything else for failure.
#   - For action, the return value is ignored; pure actions can return
#     implicitly.
#   - On bad input, an action should print an error and return 0 (or just
#     return for an action edge). The engine catches unexpected Tcl errors
#     as a safety net but actions should not rely on this.
#
# Command name shorthand:
#   s(ummary) means "s" is the required prefix and "ummary" is the optional
#   completion — any prefix s, su, sum, ..., summary matches. Ambiguous
#   matches are reported at runtime; graph authors disambiguate by choosing
#   sufficient required prefixes (e.g. s(ave), su(b) when both are wanted).
#
# Built-in commands:
#   help, ? — list the current state's commands with their help text
#            (only used if the graph does not define them itself)
#
# Dispatch return codes:
#   `dispatch` returns one of:
#       ok           — action ran, do_goto stayed, built-in help, or empty line
#       unknown      — no command matched
#       ambiguous    — multiple commands matched
#       transitioned — state pushed (goto, do_goto truthy) or popped without exit
#       exited       — quit, pop emptied the stack, or engine already dead
#       error        — invoked action raised a Tcl error
#   Useful for GUI/programmatic callers; `run` itself ignores them.
#
# Usage:
#   package require cmdgraph
#   cmdgraph::Engine create repl $graph root
#   repl run

package require TclOO

namespace eval cmdgraph {
    namespace export Engine arg_int_n arg_real_n version

    variable version_major 1
    variable version_minor 0
    variable version_patch 0

    proc version {} {
        variable version_major
        variable version_minor
        variable version_patch
        return [dict create \
            major  $version_major \
            minor  $version_minor \
            patch  $version_patch \
            string "$version_major.$version_minor.$version_patch"]
    }

    # Single printable delimiter by deliberate choice: tab removed
    # (non-printable delimiters are undiagnosable).
    variable arg_delimiters " "

    # Construct a spec list of n int/real slots all with the same name.
    # Use in the args= field: args [concat [cmdgraph::arg_real_n pt 3] {{label char}}]
    proc arg_int_n {name n} {
        set result {}
        for {set i 0} {$i < $n} {incr i} { lappend result [list $name int] }
        return $result
    }

    proc arg_real_n {name n} {
        set result {}
        for {set i 0} {$i < $n} {incr i} { lappend result [list $name real] }
        return $result
    }

    # Action-side helper. Returns the current state's context. Reliable when
    # called from inside an action proc or an on_enter proc; otherwise returns
    # the empty string. For multi-engine setups, use [$engine current_context]
    # directly rather than this convenience proc.
    variable current_context ""
    proc context {} {
        variable current_context
        return $current_context
    }
}

oo::class create cmdgraph::Engine {
    variable graph stack initial_state in_chan out_chan err_chan last_message last_error

    constructor {graph_def initial} {
        set in_chan stdin
        set out_chan stdout
        set err_chan stderr
        set last_message ""
        set last_error ""

        # Three passes:
        #   1. Parse every state's commands (specs, edges, help) into canonical form.
        #   2. Resolve `includes` — merge command sets from included states. State's
        #      own commands win over included; later includes win over earlier.
        #   3. Validate goto/do_goto targets exist and are concrete (have a prompt).
        #      States with no `prompt` are abstract — usable as include targets only.
        #
        # Pass 1: parse
        set graph {}
        dict for {state sdef} $graph_def {
            set parsed_cmds {}
            dict for {spec edge} [dict get $sdef commands] {
                lassign [my parse_spec $spec] req opt
                dict set parsed_cmds $spec [dict create \
                    req $req \
                    opt $opt \
                    edge [my parse_edge $edge]]
            }
            dict set sdef commands $parsed_cmds
            dict set graph $state $sdef
        }
        # Pass 2: merge includes
        set resolved {}
        dict for {state sdef} $graph {
            set commands [dict get $sdef commands]
            if {[dict exists $sdef includes]} {
                foreach inc_name [dict get $sdef includes] {
                    if {![dict exists $graph $inc_name]} {
                        error "cmdgraph: state '$state' includes unknown state '$inc_name'"
                    }
                    set inc_cmds [dict get $graph $inc_name commands]
                    set commands [dict merge $inc_cmds $commands]
                }
            }
            dict set sdef commands $commands
            dict set resolved $state $sdef
        }
        set graph $resolved
        # Pass 3: validate transitions
        dict for {state sdef} $graph {
            dict for {spec data} [dict get $sdef commands] {
                set edge [dict get $data edge]
                set kind [dict get $edge kind]
                if {$kind in {goto do_goto}} {
                    set target [dict get $edge target]
                    if {![dict exists $graph $target]} {
                        error "cmdgraph: state '$state' has '$spec' targeting unknown state '$target'"
                    }
                    if {![dict exists $graph $target prompt]} {
                        error "cmdgraph: state '$state' has '$spec' targeting abstract state '$target' (no prompt)"
                    }
                }
            }
        }
        # Pass 4: enforce DAG. The structural graph formed by goto/do_goto edges
        # between concrete states must be acyclic — pop is the return path,
        # abstract states are command mix-ins, not nodes. DFS with white/gray/
        # black colouring detects back-edges.
        set forward {}
        dict for {state sdef} $graph {
            if {![dict exists $sdef prompt]} continue
            set targets {}
            dict for {spec data} [dict get $sdef commands] {
                set edge [dict get $data edge]
                if {[dict get $edge kind] in {goto do_goto}} {
                    lappend targets [dict get $edge target]
                }
            }
            dict set forward $state $targets
        }
        set color {}
        dict for {state _} $forward { dict set color $state 0 }
        set parent {}
        dict for {state _} $forward {
            if {[dict get $color $state] == 0} {
                my detect_cycle $state forward color parent
            }
        }
        # Validate initial state
        if {![dict exists $graph $initial]} {
            error "cmdgraph: initial state '$initial' not in graph"
        }
        if {![dict exists $graph $initial prompt]} {
            error "cmdgraph: initial state '$initial' is abstract (no prompt)"
        }
        # Stack holds [list state context] pairs; root has empty context
        set initial_state $initial
        set stack [list [list $initial ""]]
    }

    # Recursive DFS helper for the DAG check. Mutates color/parent via upvar.
    # Raises "cmdgraph: cycle detected: A -> B -> ... -> A" on a back-edge.
    method detect_cycle {u forward_var color_var parent_var} {
        upvar 1 $forward_var forward
        upvar 1 $color_var   color
        upvar 1 $parent_var  parent
        dict set color $u 1
        foreach v [dict get $forward $u] {
            switch [dict get $color $v] {
                0 {
                    dict set parent $v $u
                    my detect_cycle $v forward color parent
                }
                1 {
                    set path [list $u]
                    set cur $u
                    while {$cur ne $v} {
                        set cur [dict get $parent $cur]
                        lappend path $cur
                    }
                    set rev [lreverse $path]
                    lappend rev $v
                    error "cmdgraph: cycle detected: [join $rev { -> }]"
                }
            }
        }
        dict set color $u 2
    }

    method parse_spec {spec} {
        if {[regexp {^([^(]+)\(([^)]*)\)$} $spec _ req opt]} {
            return [list $req $opt]
        }
        return [list $spec ""]
    }

    method parse_edge {edge} {
        set kind   [lindex $edge 0]
        set target ""
        set proc_  ""
        set help   ""
        set args   {}
        switch $kind {
            action {
                set proc_ [lindex $edge 1]
                set rest  [lrange $edge 2 end]
            }
            goto {
                set target [lindex $edge 1]
                set rest   [lrange $edge 2 end]
            }
            do_goto {
                set target [lindex $edge 1]
                set proc_  [lindex $edge 2]
                set rest   [lrange $edge 3 end]
            }
            do_pop {
                set proc_ [lindex $edge 1]
                set rest  [lrange $edge 2 end]
            }
            pop - quit {
                set rest [lrange $edge 1 end]
            }
            default {
                error "cmdgraph: unknown edge kind \"$kind\""
            }
        }
        foreach {k v} $rest {
            switch -- $k {
                help { set help $v }
                args { set args [my parse_arg_spec $v] }
            }
        }
        return [dict create kind $kind target $target proc $proc_ help $help args $args]
    }

    method parse_arg_spec {raw} {
        set result {}
        foreach item $raw {
            if {[llength $item] < 2 || [llength $item] > 3} {
                error "cmdgraph: bad arg spec '$item' (expected {name int|real|char|rest ?optional?})"
            }
            lassign $item name kind opt
            switch -- $kind {
                int - integer {
                    set kind int
                }
                real - double {
                    set kind real
                }
                char - string {
                    set kind char
                }
                rest {
                    set kind rest
                }
                default {
                    error "cmdgraph: bad arg spec '$item' (unknown kind '$kind')"
                }
            }
            set optional 0
            if {[llength $item] == 3} {
                if {$opt eq "optional"} {
                    set optional 1
                } elseif {[string is boolean -strict $opt]} {
                    set optional [string is true -strict $opt]
                } else {
                    error "cmdgraph: bad arg spec '$item' (third field must be optional or boolean)"
                }
            }
            lappend result [dict create name $name kind $kind optional $optional]
        }
        for {set i 0} {$i < [llength $result]} {incr i} {
            if {[dict get [lindex $result $i] kind] eq "rest"
                && $i != [llength $result] - 1} {
                error "cmdgraph: a rest arg must be the last spec slot"
            }
        }
        return $result
    }

    method run {} {
        while {[my is_running]} {
            set sdef [dict get $graph [my top_state]]
            my emit_prompt [dict get $sdef prompt]
            if {[gets $in_chan line] < 0} break
            my dispatch $line
        }
    }

    # Drive the engine from a script file. Each non-blank, non-comment line is
    # echoed (prompt+line) and dispatched. Stops at EOF or engine exit. Returns
    # 1 on success, 0 if the file cannot be opened.
    # Drive the engine from a script file. Returns a dict
    # {ok 0|1 stat <code> errmsg <msg> line <n>}. ok=1 iff the file opened
    # and every dispatched line succeeded (or the script quit cleanly). On
    # failure: stat="open" for a file-open failure (line 0), otherwise the
    # failing line's dispatch code (unknown|ambiguous|error) with line the
    # 1-based file line number; errmsg is the diagnostic text. Stops at the
    # first failing line (engine left in whatever state it produced).
    method run_file {path {echo 1}} {
        if {[catch {open $path r} fh]} {
            my set_error "could not open script file: $path"
            return [dict create ok 0 stat open errmsg $last_error line 0]
        }
        set lineno 0
        set result [dict create ok 1 stat "" errmsg "" line 0]
        try {
            while {[my is_running] && [gets $fh line] >= 0} {
                incr lineno
                set trimmed [string trim $line]
                if {$trimmed eq ""} continue
                if {[string index $trimmed 0] eq "#"} continue
                set sdef [dict get $graph [my top_state]]
                if {$echo} {
                    my emit_info "[dict get $sdef prompt]$line"
                }
                set rc [my dispatch $line]
                if {$rc in {unknown ambiguous error}} {
                    set msg [expr {$rc eq "error" ? $last_error : $last_message}]
                    set result [dict create ok 0 stat $rc errmsg $msg line $lineno]
                    break
                }
            }
        } finally {
            close $fh
        }
        return $result
    }

    # Return a finalized engine to its initial runtime state without
    # rebuilding: stack rewound to the initial state, contexts dropped,
    # last_message/last_error cleared. The graph is untouched.
    method reset {} {
        set stack [list [list $initial_state ""]]
        set last_message ""
        set last_error ""
    }

    method top_state {} { return [lindex [lindex $stack end] 0] }
    method top_ctx   {} { return [lindex [lindex $stack end] 1] }

    method current_state   {} { return [my top_state] }
    method current_context {} { return [my top_ctx] }

    method is_running {} {
        return [expr {[llength $stack] > 0}]
    }

    # Read-only enumeration of the current state's commands for menu/GUI
    # builders. Pure walk of the already-resolved commands dict (includes
    # merged at construction): no matching, no parsing. Synthetic help/?
    # are injected at dispatch and not in the dict, so they are naturally
    # excluded; a graph's own help override is a real command and included.
    # Empty list when not running. Depends only on the current state, so
    # callers may cache it (the graph is immutable after construction).
    method available_commands {} {
        if {![my is_running]} { return {} }
        set sdef [dict get $graph [my top_state]]
        set result {}
        dict for {spec data} [dict get $sdef commands] {
            set edge [dict get $data edge]
            lappend result [dict create \
                spec   $spec \
                req    [dict get $data req] \
                opt    [dict get $data opt] \
                kind   [dict get $edge kind] \
                target [dict get $edge target] \
                args   [dict get $edge args] \
                help   [dict get $edge help]]
        }
        return $result
    }

    # State names from initial to current top. Empty when not running.
    method state_path {} {
        return [lmap entry $stack {lindex $entry 0}]
    }

    method set_io_channels {in out err} {
        set in_chan $in
        set out_chan $out
        set err_chan $err
    }

    method last_message {} {
        return $last_message
    }

    method last_error {} {
        return $last_error
    }

    method dispatch {line} {
        if {![my is_running]} { return "exited" }
        set sdef [dict get $graph [my top_state]]
        lassign [my split_first_token $line] cmd rest
        if {$cmd eq ""} { return "ok" }
        set matches [my find_matches $sdef $cmd]
        switch [llength $matches] {
            0 {
                if {$cmd in {help ?}} {
                    my show_help $sdef
                    return "ok"
                }
                my emit_info "unknown: $cmd"
                return "unknown"
            }
            1 {
                set edge [dict get [lindex $matches 0] edge]
                set spec [dict get $edge args]
                set rest_idx 0
                if {[llength $spec] > 0
                    && [dict get [lindex $spec end] kind] eq "rest"} {
                    set rest_idx [llength $spec]
                }
                if {$rest_idx > 0} {
                    # Spec ends in a rest slot: tokenise only the leading
                    # structured args, then take the remainder verbatim.
                    set n_lead [expr {$rest_idx - 1}]
                    lassign [my parse_args_lead $rest $n_lead] args tail
                    # Quote balance only constrains the structured lead; the
                    # rest portion is free text and may contain a lone ".
                    set lead_src [string range $rest 0 \
                        [expr {[string length $rest] - [string length $tail] - 1}]]
                    if {![my has_balanced_quotes $lead_src]} {
                        my emit_error "unmatched quote in arguments"
                        return "error"
                    }
                    set tail [my strip_leading_arg_space $tail]
                    if {$tail ne ""} { lappend args $tail }
                } else {
                    if {![my has_balanced_quotes $rest]} {
                        my emit_error "unmatched quote in arguments"
                        return "error"
                    }
                    set args [my parse_args $rest]
                }
                set validation [my validate_args $spec $args]
                if {![dict get $validation ok]} {
                    my emit_error [dict get $validation msg]
                    return "error"
                }
                return [my apply_edge $edge $args]
            }
            default {
                set names [lmap m $matches {dict get $m spec}]
                my emit_info "ambiguous: $cmd matches [join $names {, }]"
                return "ambiguous"
            }
        }
    }

    method split_first_token {line} {
        set trimmed [my strip_leading_arg_space $line]
        if {$trimmed eq ""} {
            return [list "" ""]
        }
        set sep [my first_arg_separator $trimmed]
        if {$sep < 0} {
            return [list $trimmed ""]
        }
        set cmd [string range $trimmed 0 [expr {$sep - 1}]]
        set rest [my strip_leading_arg_space [string range $trimmed [expr {$sep + 1}] end]]
        return [list $cmd $rest]
    }

    method strip_leading_arg_space {text} {
        if {$text eq ""} {
            return ""
        }
        if {[string first [string index $text 0] $::cmdgraph::arg_delimiters] >= 0} {
            tailcall my strip_leading_arg_space [string range $text 1 end]
        }
        return $text
    }

    method first_arg_separator {text} {
        set in_quote 0
        set n [string length $text]
        for {set i 0} {$i < $n} {incr i} {
            set ch [string index $text $i]
            if {$ch eq "\""} {
                set in_quote [expr {!$in_quote}]
            } elseif {!$in_quote && [string first $ch $::cmdgraph::arg_delimiters] >= 0} {
                return $i
            }
        }
        return -1
    }

    method has_balanced_quotes {text} {
        return [expr {([my count_char $text "\""] % 2) == 0}]
    }

    method count_char {text ch {acc 0}} {
        set p [string first $ch $text]
        if {$p < 0} {
            return $acc
        }
        tailcall my count_char [string range $text [expr {$p + 1}] end] $ch [expr {$acc + 1}]
    }

    method parse_args {text {acc {}}} {
        set trimmed [my strip_leading_arg_space $text]
        if {$trimmed eq ""} {
            return $acc
        }
        set sep [my first_arg_separator $trimmed]
        if {$sep < 0} {
            set token $trimmed
            set rest ""
        } else {
            set token [string range $trimmed 0 [expr {$sep - 1}]]
            set rest [string range $trimmed [expr {$sep + 1}] end]
        }
        lappend acc [my unquote_arg_token $token]
        tailcall my parse_args $rest $acc
    }

    # Tokenise at most n_lead leading args (like parse_args), then return
    # {parsed-list unconsumed-tail}. The tail is a content-suffix of $text,
    # so [string length $text] - [string length $tail] is the consumed
    # prefix length. Used for the rest-of-line slot.
    method parse_args_lead {text n_lead {acc {}}} {
        if {[llength $acc] >= $n_lead} {
            return [list $acc $text]
        }
        set trimmed [my strip_leading_arg_space $text]
        if {$trimmed eq ""} {
            return [list $acc ""]
        }
        set sep [my first_arg_separator $trimmed]
        if {$sep < 0} {
            set token $trimmed
            set rest ""
        } else {
            set token [string range $trimmed 0 [expr {$sep - 1}]]
            set rest [string range $trimmed [expr {$sep + 1}] end]
        }
        lappend acc [my unquote_arg_token $token]
        tailcall my parse_args_lead $rest $n_lead $acc
    }

    method unquote_arg_token {token} {
        if {[string length $token] >= 2
            && [string index $token 0] eq "\""
            && [string index $token end] eq "\""} {
            return [string range $token 1 end-1]
        }
        return $token
    }

    method find_matches {sdef cmd} {
        set result {}
        set clen [string length $cmd]
        dict for {spec data} [dict get $sdef commands] {
            set req [dict get $data req]
            set opt [dict get $data opt]
            set full $req$opt
            set rlen [string length $req]
            set flen [string length $full]
            if {$clen >= $rlen && $clen <= $flen
                && [string equal -length $clen $cmd $full]} {
                lappend result [dict create spec $spec edge [dict get $data edge]]
            }
        }
        return $result
    }

    method validate_args {spec arg_list} {
        if {[llength $spec] == 0} {
            return [dict create ok 1 msg ""]
        }
        set n_args [llength $arg_list]

        set n_required 0
        for {set i 0} {$i < [llength $spec]} {incr i} {
            if {![dict get [lindex $spec $i] optional]} {
                set n_required [expr {$i + 1}]
            }
        }

        if {$n_args < $n_required} {
            set missing [dict get [lindex $spec $n_args] name]
            return [dict create ok 0 msg "missing required argument <$missing>"]
        }

        if {$n_args > [llength $spec]} {
            return [dict create ok 0 msg "unexpected extra argument"]
        }

        for {set i 0} {$i < $n_args} {incr i} {
            set arg [lindex $arg_list $i]
            set slot [lindex $spec $i]
            set kind [dict get $slot kind]
            if {$kind eq "rest"} { continue }
            set actual [my token_kind $arg]
            if {$actual ne $kind} {
                set name [dict get $slot name]
                switch -- $kind {
                    int  { set expected integer }
                    real { set expected real }
                    char { set expected string }
                }
                return [dict create ok 0 msg "argument <$name> expects $expected"]
            }
        }

        return [dict create ok 1 msg ""]
    }

    method token_kind {token} {
        if {[regexp {^[+-]?[0-9]+$} $token]} {
            return int
        }
        if {[my is_real_token $token]} {
            return real
        }
        return char
    }

    method is_real_token {token} {
        return [regexp {^[+-]?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))([eEdD][+-]?[0-9]+)?$} $token]
    }

    method apply_edge {edge arg_list} {
        switch [dict get $edge kind] {
            action {
                set r [my invoke [dict get $edge proc] $arg_list]
                if {[dict get $r errored]} { return "error" }
                return "ok"
            }
            goto {
                lappend stack [list [dict get $edge target] ""]
                my fire_on_enter
                return "transitioned"
            }
            do_goto {
                set r [my invoke [dict get $edge proc] $arg_list]
                if {[dict get $r errored]} { return "error" }
                set v [dict get $r value]
                if {$v ne ""} {
                    lappend stack [list [dict get $edge target] $v]
                    my fire_on_enter
                    return "transitioned"
                }
                return "ok"
            }
            pop {
                set stack [lrange $stack 0 end-1]
                if {![my is_running]} { return "exited" }
                return "transitioned"
            }
            do_pop {
                set r [my invoke [dict get $edge proc] $arg_list]
                if {[dict get $r errored]} { return "error" }
                set stack [lrange $stack 0 end-1]
                if {![my is_running]} { return "exited" }
                return "transitioned"
            }
            quit {
                set stack {}
                return "exited"
            }
        }
    }

    method fire_on_enter {} {
        if {![my is_running]} return
        set sdef [dict get $graph [my top_state]]
        if {![dict exists $sdef on_enter]} return
        set ::cmdgraph::current_context [my top_ctx]
        set rc [catch {[dict get $sdef on_enter]} err]
        set ::cmdgraph::current_context ""
        if {$rc} {
            my emit_error "error in on_enter for [my top_state]: $err"
        }
    }

    # Invokes an action proc with the current state's context visible via
    # cmdgraph::context. Returns a dict {errored 0|1 value V} so callers can
    # distinguish a Tcl error from a falsy return. Value semantics:
    #   - empty / boolean-false (0, false, no, off) → value is ""
    #   - anything else → value is the proc's return (used as context for do_goto)
    # On Tcl errors, errored=1, value="" and the error message is printed.
    method invoke {proc_name arg_list} {
        set ::cmdgraph::current_context [my top_ctx]
        set rc [catch {$proc_name {*}$arg_list} result]
        set ::cmdgraph::current_context ""
        if {$rc} {
            my emit_error "error: $result"
            return [dict create errored 1 value "" errmsg $result]
        }
        if {[string is boolean -strict $result] && ![string is true -strict $result]} {
            return [dict create errored 0 value "" errmsg ""]
        }
        return [dict create errored 0 value $result errmsg ""]
    }

    # Usage label for a command: the spec followed by its arg specs.
    # Required args render as <name:kind>, optional as [name:kind].
    method command_usage {spec argspec} {
        set label $spec
        foreach a $argspec {
            set name [dict get $a name]
            set kind [dict get $a kind]
            if {[dict get $a optional]} {
                append label " \[$name:$kind\]"
            } else {
                append label " <$name:$kind>"
            }
        }
        return $label
    }

    method show_help {sdef} {
        set max_len 0
        set rows {}
        dict for {spec data} [dict get $sdef commands] {
            set label [my command_usage $spec [dict get $data edge args]]
            if {[string length $label] > $max_len} {
                set max_len [string length $label]
            }
            lappend rows [list $label [dict get $data edge help]]
        }
        foreach row $rows {
            lassign $row label help
            my emit_info [format "  %-*s  %s" $max_len $label $help]
        }
    }

    method emit_prompt {msg} {
        set last_message $msg
        if {$out_chan ne ""} {
            puts -nonewline $out_chan $msg
            flush $out_chan
        }
    }

    method emit_info {msg} {
        set last_message $msg
        if {$out_chan ne ""} {
            puts $out_chan $msg
        }
    }

    method emit_error {msg} {
        my set_error $msg
        if {$err_chan ne ""} {
            puts $err_chan $msg
        }
    }

    method set_error {msg} {
        set last_error $msg
    }
}

package provide cmdgraph 1.0.0
