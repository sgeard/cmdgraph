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
#       - return ""               → no transition (stay in current state)
#       - return any other value  → transition; the value becomes the context
#   Strings like "0", "no", "false" are valid contexts and DO transition —
#   only the empty string means stay.
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
# Action callbacks:
#   The proc_name slot of action / do_goto / do_pop accepts either a bare
#   command name or a list-formed callback such as `[list $obj method_name]`.
#   The same form is accepted for `on_enter`. This is what cmdgraph::Shell
#   relies on to bind commands to instance methods.
#
# Edge kinds:
#   action  proc_name              — invoke proc, ignore return value, stay
#   goto    state_name             — push state, no proc call
#   do_goto state_name proc_name   — invoke proc; if it returns a non-empty
#                                    string push the target state (the
#                                    returned string becomes the new state's
#                                    context); empty string stays. "0",
#                                    "no", "false" are valid contexts.
#   pop                            — pop the state stack (e.g. "esc"/"back")
#   do_pop  proc_name              — invoke proc, then pop on success (the
#                                    commit-and-return pattern); a Tcl
#                                    error in the proc leaves the stack
#                                    alone
#   swap    state_name             — replace the top frame with the target
#                                    (pop-then-push), empty context, no proc
#   do_swap state_name proc_name   — invoke proc; a non-empty return replaces
#                                    the top frame with the target (the
#                                    returned string becomes the new context);
#                                    empty string stays. Like do_goto but
#                                    replace-not-push — the tool-switch edge.
#   quit                           — exit the engine
#
# swap/do_swap replace the top frame so they are inherently cyclic and, like
# pop, are exempt from the goto/do_goto DAG (acyclicity) check.
#
# Action contract:
#   - Action procs take {args} (variadic), parse their own arguments.
#   - A command may declare `args {{name int|real|char ?optional?} ...}`.
#     When present, the engine validates argument count and token types before
#     invoking the action. Only trailing positions may be omitted.
#   - For do_goto, the proc must return the new state's context as a string:
#     any non-empty string triggers the transition (and becomes the context);
#     "" stays. "0", "no", "false" are valid contexts that DO transition —
#     a do_goto wanting to refuse the transition must return "" explicitly.
#   - For action, the return value is ignored; pure actions can return
#     implicitly.
#   - On bad input, a do_goto action should print an error and return "";
#     an action edge can just return. The engine catches unexpected Tcl
#     errors as a safety net but actions should not rely on this.
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
#       transitioned — state pushed (goto, do_goto non-empty return) or popped without exit
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
    variable version_minor 4
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
        return [lrepeat $n [list $name int]]
    }

    proc arg_real_n {name n} {
        return [lrepeat $n [list $name real]]
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

# ----------------------------------------------------------------------------
# cmdgraph::encoding - what encoding is this input in, and do we read it?
# ----------------------------------------------------------------------------
#
# The engine reads ASCII and UTF-8. Legacy 8-bit sets cannot be told apart
# from those and pass through untouched (`plain`). Everything else that can
# be recognised - by a byte-order mark or other leading signature, or by the
# NUL bytes a 16- or 32-bit encoding leaves when it has no mark - is refused.
#
# Encodings are named by token:
#   plain utf-8-bom                                  (read)
#   utf-16le utf-16be utf-32le utf-32be utf-7 utf-1
#   utf-ebcdic scsu bocu-1 gb18030 wide-no-bom       (refused)
#
# `run`, `run_file` and `Shell cmdloop` call `gets` below themselves;
# `strip_bom` is for a caller that reads its own lines and hands them to
# `dispatch`.
namespace eval cmdgraph::encoding {
    namespace export strip_bom name supported

    # {signature token}, tested in this order, so a signature that begins
    # with a shorter one (UTF-32 LE starts with the UTF-16 LE mark) must
    # come first. Each signature character stands for one byte.
    variable signatures {
        "\xFF\xFE\x00\x00" utf-32le
        "\x00\x00\xFE\xFF" utf-32be
        "\xDD\x73\x66\x73" utf-ebcdic
        "\x84\x31\x95\x33" gb18030
        "\xEF\xBB\xBF"     utf-8-bom
        "\x2B\x2F\x76"     utf-7
        "\xF7\x64\x4C"     utf-1
        "\x0E\xFE\xFF"     scsu
        "\xFB\xEE\x28"     bocu-1
        "\xFF\xFE"         utf-16le
        "\xFE\xFF"         utf-16be
    }
    # Expand the backslash escapes once, at load.
    set signatures [subst -nocommands -novariables $signatures]

    variable names {
        plain       {ASCII / UTF-8}
        utf-8-bom   {UTF-8 with a byte-order mark}
        utf-16le    {UTF-16 / UCS-2, little-endian}
        utf-16be    {UTF-16 / UCS-2, big-endian}
        utf-32le    {UTF-32 / UCS-4, little-endian}
        utf-32be    {UTF-32 / UCS-4, big-endian}
        utf-7       {UTF-7}
        utf-1       {UTF-1}
        utf-ebcdic  {UTF-EBCDIC}
        scsu        {SCSU}
        bocu-1      {BOCU-1}
        gb18030     {GB18030}
        wide-no-bom {NUL bytes; probably UTF-16 / UCS-2 or UTF-32 / UCS-4 without a byte-order mark}
    }

    # Channel encodings Tcl itself decodes from 16- or 32-bit units. A
    # channel the caller configured this way is read as it stands.
    variable wide_channel {^(unicode|ucs-2|ucs-4|utf-16|utf-32)}

    # Display name of a token, as used in the engine's messages.
    proc name {enc} {
        variable names
        if {[dict exists $names $enc]} { return [dict get $names $enc] }
        return unknown
    }

    # 1 for the encodings the engine reads.
    proc supported {enc} {
        return [expr {$enc in {plain utf-8-bom}}]
    }

    # The one wording used for a refused encoding (parity contract).
    proc message {enc} {
        return "unsupported encoding ([name $enc]); expected ASCII or UTF-8"
    }

    # Classify the first line of an input stream, held in the caller's
    # variable, and drop a UTF-8 byte-order mark from it. Returns the token.
    #
    # The line may be raw bytes (one character per byte, as a binary or
    # iso8859-1 channel delivers them) or already decoded: a decoded mark
    # arrives as the single character U+FEFF and is dropped the same way.
    proc strip_bom {textVar} {
        variable signatures
        upvar 1 $textVar text

        set enc plain
        if {[string index $text 0] eq "\uFEFF"} {
            set text [string range $text 1 end]
            set enc utf-8-bom
        } else {
            foreach {sig token} $signatures {
                if {[string equal -length [string length $sig] $sig $text]
                        && [string length $text] >= [string length $sig]} {
                    set enc $token
                    if {$enc eq "utf-8-bom"} {
                        set text [string range $text [string length $sig] end]
                    }
                    break
                }
            }
        }
        # A NUL is never part of a command, so in text with no signature (or
        # behind a UTF-8 mark) it means a wide encoding with no mark.
        if {[supported $enc] && [string first \x00 $text] >= 0} {
            set enc wide-no-bom
        }
        return $enc
    }

    # [gets] with the encoding check. Reads one line of $chan into the
    # caller's lineVar and its token into encVar; returns what [gets] does.
    # `first` says this is the first line of the stream: it is then read
    # byte for byte, so that a signature is seen exactly as written whatever
    # the channel's encoding, and decoded afterwards. Later lines are only
    # tested for NUL bytes.
    proc gets {chan lineVar encVar first} {
        variable wide_channel
        upvar 1 $lineVar line $encVar enc

        set enc plain
        if {!$first} {
            set n [::gets $chan line]
            if {[string first \x00 $line] >= 0} { set enc wide-no-bom }
            return $n
        }

        set chan_enc [fconfigure $chan -encoding]
        if {[regexp -- $wide_channel $chan_enc]} {
            # Tcl is decoding a wide encoding the caller asked for.
            set n [::gets $chan line]
            if {[string index $line 0] eq "\uFEFF"} {
                set line [string range $line 1 end]
                set enc utf-8-bom
            }
            return $n
        }

        fconfigure $chan -encoding iso8859-1
        try {
            set n [::gets $chan line]
        } finally {
            fconfigure $chan -encoding $chan_enc
        }
        if {$n < 0} { return $n }

        set enc [strip_bom line]
        if {[supported $enc] && $chan_enc ni {binary iso8859-1}} {
            set line [decode $chan $chan_enc $line]
        }
        return $n
    }

    # Decode a line read byte for byte as the channel itself would have.
    proc decode {chan chan_enc bytes} {
        set raw [encoding convertto iso8859-1 $bytes]
        # Tcl 9 channels carry a -profile that decides how invalid bytes are
        # treated; Tcl 8.6 has no such option.
        if {[catch {fconfigure $chan -profile} profile]} {
            return [encoding convertfrom $chan_enc $raw]
        }
        return [encoding convertfrom -profile $profile $chan_enc $raw]
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
        # Pass 1: parse. full/rlen/flen are precomputed here so find_matches
        # (per command, per dispatched line) never rebuilds the full name or
        # re-measures it - the graph is immutable after construction.
        set graph {}
        dict for {state sdef} $graph_def {
            set parsed_cmds {}
            dict for {spec edge} [dict get $sdef commands] {
                lassign [my parse_spec $spec] req opt
                dict set parsed_cmds $spec [dict create \
                    req $req \
                    opt $opt \
                    full $req$opt \
                    rlen [string length $req] \
                    flen [string length $req$opt] \
                    edge [my parse_edge $spec $edge]]
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
                if {$kind in {goto do_goto swap do_swap}} {
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
        # swap/do_swap replace the top frame (pop-then-push) and are inherently
        # cyclic so they too are exempt (built only from goto/do_goto below),
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

    method parse_edge {spec edge} {
        set kind   [lindex $edge 0]
        set target ""
        set proc_  ""
        set help   ""
        set args   {}
        switch $kind {
            action {
                set proc_ [lindex $edge 1]
                set rest  [lrange $edge 2 end]
                if {$proc_ eq ""} {
                    error "cmdgraph: action edge '$spec' missing required proc"
                }
            }
            goto {
                set target [lindex $edge 1]
                set rest   [lrange $edge 2 end]
                if {$target eq ""} {
                    error "cmdgraph: goto edge '$spec' missing required target"
                }
            }
            swap {
                set target [lindex $edge 1]
                set rest   [lrange $edge 2 end]
                if {$target eq ""} {
                    error "cmdgraph: swap edge '$spec' missing required target"
                }
            }
            do_goto {
                set target [lindex $edge 1]
                set proc_  [lindex $edge 2]
                set rest   [lrange $edge 3 end]
                if {$target eq ""} {
                    error "cmdgraph: do_goto edge '$spec' missing required target"
                }
                if {$proc_ eq ""} {
                    error "cmdgraph: do_goto edge '$spec' missing required proc"
                }
            }
            do_swap {
                set target [lindex $edge 1]
                set proc_  [lindex $edge 2]
                set rest   [lrange $edge 3 end]
                if {$target eq ""} {
                    error "cmdgraph: do_swap edge '$spec' missing required target"
                }
                if {$proc_ eq ""} {
                    error "cmdgraph: do_swap edge '$spec' missing required proc"
                }
            }
            do_pop {
                set proc_ [lindex $edge 1]
                set rest  [lrange $edge 2 end]
                if {$proc_ eq ""} {
                    error "cmdgraph: do_pop edge '$spec' missing required proc"
                }
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

    # Run an interactive loop on the input channel. The loop ends at end of
    # input, on quit, or - having written the reason to the error channel -
    # at a line in an unsupported encoding. Returns 0 in that last case,
    # otherwise 1.
    method run {} {
        set first 1
        while {[my is_running]} {
            set sdef [dict get $graph [my top_state]]
            my emit_prompt [dict get $sdef prompt]
            if {[::cmdgraph::encoding::gets $in_chan line enc $first] < 0} break
            set first 0
            if {![::cmdgraph::encoding::supported $enc]} {
                my emit_error [::cmdgraph::encoding::message $enc]
                return 0
            }
            my dispatch $line
        }
        return 1
    }

    # Drive the engine from a script file. Each non-blank, non-comment line is
    # echoed (prompt+line) and dispatched. Stops at EOF or engine exit. Returns
    # 1 on success, 0 if the file cannot be opened.
    # Drive the engine from a script file. Returns a dict
    # {ok 0|1 stat <code> errmsg <msg> line <n>}. ok=1 iff the file opened
    # and every dispatched line succeeded (or the script quit cleanly). On
    # failure: stat="open" for a file-open failure (line 0), stat="encoding"
    # for a line in an encoding the engine does not read (that line is not
    # dispatched), otherwise the failing line's dispatch code
    # (unknown|ambiguous|error); line is the 1-based file line number; errmsg
    # is the diagnostic text. Stops at the first failing line (engine left in
    # whatever state it produced).
    method run_file {path {echo 1}} {
        if {[catch {open $path r} fh]} {
            my set_error "could not open script file: $path"
            return [dict create ok 0 stat open errmsg $last_error line 0]
        }
        set lineno 0
        set result [dict create ok 1 stat "" errmsg "" line 0]
        try {
            while {[my is_running]
                   && [::cmdgraph::encoding::gets $fh line enc [expr {$lineno == 0}]] >= 0} {
                incr lineno
                if {![::cmdgraph::encoding::supported $enc]} {
                    # Populated silently, like the open failure: the error
                    # channel is for events raised by a dispatched line.
                    my set_error "[::cmdgraph::encoding::message $enc]: $path"
                    set result [dict create ok 0 stat encoding errmsg $last_error line $lineno]
                    break
                }
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

    # The tokenizer walks the ORIGINAL line by index (start/sep positions);
    # tokens are the only substrings ever copied out. The previous version
    # recursed on [string range] suffixes, copying the remaining text per
    # delimiter/token - O(line^2) on long argument lines.
    method split_first_token {line} {
        set start [my skip_arg_space $line 0]
        if {$start >= [string length $line]} {
            return [list "" ""]
        }
        set sep [my first_arg_separator $line $start]
        if {$sep < 0} {
            return [list [string range $line $start end] ""]
        }
        set cmd [string range $line $start [expr {$sep - 1}]]
        set rest [my strip_leading_arg_space [string range $line [expr {$sep + 1}] end]]
        return [list $cmd $rest]
    }

    method strip_leading_arg_space {text} {
        return [string trimleft $text $::cmdgraph::arg_delimiters]
    }

    # The first non-delimiter position at or after start ([string length]
    # when the remainder is all delimiters).
    method skip_arg_space {text start} {
        set n [string length $text]
        while {$start < $n
               && [string first [string index $text $start] $::cmdgraph::arg_delimiters] >= 0} {
            incr start
        }
        return $start
    }

    # The first unquoted delimiter position at or after start, -1 if none.
    method first_arg_separator {text {start 0}} {
        set in_quote 0
        set n [string length $text]
        for {set i $start} {$i < $n} {incr i} {
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

    method count_char {text ch {start 0} {acc 0}} {
        set p [string first $ch $text $start]
        if {$p < 0} {
            return $acc
        }
        tailcall my count_char $text $ch [expr {$p + 1}] [expr {$acc + 1}]
    }

    method parse_args {text {start 0} {acc {}}} {
        set start [my skip_arg_space $text $start]
        if {$start >= [string length $text]} {
            return $acc
        }
        set sep [my first_arg_separator $text $start]
        if {$sep < 0} {
            set token [string range $text $start end]
            set next [string length $text]
        } else {
            set token [string range $text $start [expr {$sep - 1}]]
            set next [expr {$sep + 1}]
        }
        lappend acc [my unquote_arg_token $token]
        tailcall my parse_args $text $next $acc
    }

    # Tokenise at most n_lead leading args (like parse_args), then return
    # {parsed-list unconsumed-tail}. The tail is a content-suffix of $text,
    # so [string length $text] - [string length $tail] is the consumed
    # prefix length. Used for the rest-of-line slot.
    method parse_args_lead {text n_lead {start 0} {acc {}}} {
        if {[llength $acc] >= $n_lead} {
            return [list $acc [string range $text $start end]]
        }
        set start [my skip_arg_space $text $start]
        if {$start >= [string length $text]} {
            return [list $acc ""]
        }
        set sep [my first_arg_separator $text $start]
        if {$sep < 0} {
            set token [string range $text $start end]
            set next [string length $text]
        } else {
            set token [string range $text $start [expr {$sep - 1}]]
            set next [expr {$sep + 1}]
        }
        lappend acc [my unquote_arg_token $token]
        tailcall my parse_args_lead $text $n_lead $next $acc
    }

    method unquote_arg_token {token} {
        if {[string length $token] >= 2
            && [string index $token 0] eq "\""
            && [string index $token end] eq "\""} {
            return [string range $token 1 end-1]
        }
        return $token
    }

    # The prefix match against every command in the state - the dispatch inner
    # loop. full/rlen/flen were precomputed at construction (pass 1), so each
    # candidate costs three dict gets and one length-bounded string compare.
    method find_matches {sdef cmd} {
        set result {}
        set clen [string length $cmd]
        dict for {spec data} [dict get $sdef commands] {
            if {$clen >= [dict get $data rlen] && $clen <= [dict get $data flen]
                && [string equal -length $clen $cmd [dict get $data full]]} {
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
            # Promote int → real: an integer literal is accepted in a real
            # slot.  The arg is passed through to the action as the raw token
            # (Tcl is dynamically typed; the action sees the same string).
            # Mirrors C++ ARG_REAL int-variant promotion and the Fortran
            # post-validate normalisation in dispatch_engine.
            if {$kind eq "real" && $actual eq "int"} { continue }
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
            swap {
                lset stack end [list [dict get $edge target] ""]
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
            do_swap {
                set r [my invoke [dict get $edge proc] $arg_list]
                if {[dict get $r errored]} { return "error" }
                set v [dict get $r value]
                if {$v ne ""} {
                    lset stack end [list [dict get $edge target] $v]
                    my fire_on_enter
                    return "transitioned"
                }
                return "ok"
            }
            pop {
                set stack [lreplace $stack end end]
                if {![my is_running]} { return "exited" }
                return "transitioned"
            }
            do_pop {
                set r [my invoke [dict get $edge proc] $arg_list]
                if {[dict get $r errored]} { return "error" }
                set stack [lreplace $stack end end]
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
        # Save/restore so nested dispatch (an on_enter or action that
        # re-enters the engine) doesn't clobber an outer frame's context.
        set saved $::cmdgraph::current_context
        set ::cmdgraph::current_context [my top_ctx]
        # on_enter may be a bare proc name or a list-formed callback
        # (e.g. `[list $obj on_enter_method]`); {*} handles both.
        set rc [catch {{*}[dict get $sdef on_enter]} err]
        set ::cmdgraph::current_context $saved
        if {$rc} {
            my emit_error "error in on_enter for [my top_state]: $err"
        }
    }

    # Invokes an action proc with the current state's context visible via
    # cmdgraph::context. Returns a dict {errored 0|1 value V} so callers can
    # distinguish a Tcl error from a falsy return. Value semantics:
    #   - "" (empty / unset) → no transition
    #   - anything else (including "0", "no", "false") → value is the proc's
    #     return, used as context for do_goto. A do_goto action wanting to
    #     stay must return "" explicitly.
    # On Tcl errors, errored=1, value="" and the error message is printed.
    #
    # proc_name may be a bare command (e.g. `act_outer`) or a list-formed
    # callback (e.g. `[list $obj do_thing]`). Both are expanded with {*}, so
    # an instance method on a TclOO object can be registered as an action.
    #
    # Save/restore of current_context so that an action which re-enters the
    # engine (a GUI calling $engine dispatch on a queued line, for instance)
    # doesn't reset the outer frame's context to "" on return.
    method invoke {proc_name arg_list} {
        set saved $::cmdgraph::current_context
        set ::cmdgraph::current_context [my top_ctx]
        set rc [catch {{*}$proc_name {*}$arg_list} result]
        set ::cmdgraph::current_context $saved
        if {$rc} {
            my emit_error "error: $result"
            return [dict create errored 1 value "" errmsg $result]
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

# ----------------------------------------------------------------------------
# cmdgraph::Shell — OO façade for single-state shells (Python cmd.Cmd analog)
# ----------------------------------------------------------------------------
#
# Subclass cmdgraph::Shell, define do_<spec> methods, run cmdloop. The base
# class introspects the subclass at construction time and synthesises a single
# state whose commands are bound to the matching instance methods.
#
# Conventions:
#   do_<spec>       — required: the action method. Receives the parsed args.
#                     `<spec>` is the cmdgraph command spec including any
#                     prefix/completion parens, e.g. do_g(reet) or do_quit.
#   help_<spec>     — optional: returns the help string. Empty if absent.
#   args_<spec>     — optional: returns the typed-arg spec list, same shape
#                     as the engine's `args { ... }` field, e.g.
#                     `{{name char} {age int optional}}`. Absent → variadic.
#
# Quit:
#   If the subclass does not register a command whose full spec resolves to
#   `quit`, a built-in `q(uit)` is auto-injected. Subclasses wanting custom
#   quit logic just define `do_q(uit)` themselves and call `my exit` from
#   inside it (or wherever else the shell should terminate).
#
# Lifecycle hooks (all optional; the base class calls them iff the subclass
# defines them):
#   preloop  {}             — once, before the first prompt
#   postloop {}             — once, after the loop has stopped
#   precmd   {line}         — before each dispatch; returns the (possibly
#                             rewritten) line. Returning "" skips dispatch.
#   postcmd  {rc line}      — after each dispatch; rc is the dispatch return
#                             code (ok/unknown/ambiguous/error/transitioned/
#                             exited). Return value is ignored.
#
# Usage:
#   oo::class create MyShell {
#       superclass cmdgraph::Shell
#       constructor {} { next "myshell> " }
#       method do_g(reet)    {name} { puts "Hello, $name" }
#       method args_g(reet)  {}     { return {{name char}} }
#       method help_g(reet)  {}     { return "Greet someone" }
#   }
#   [MyShell new] cmdloop

oo::class create cmdgraph::Shell {
    variable engine prompt_str in_chan out_chan exiting

    constructor {{prompt "> "}} {
        set prompt_str $prompt
        set in_chan    stdin
        set out_chan   stdout
        set exiting    0

        set cmds [my BuildCommands]
        set graph_def [dict create root [dict create \
            prompt   $prompt_str \
            commands $cmds]]

        cmdgraph::Engine create [self namespace]::engine $graph_def root
        set engine [self namespace]::engine
    }

    destructor {
        if {[info exists engine] && [info commands $engine] ne ""} {
            $engine destroy
        }
    }

    # Walk the subclass methods. Every do_<spec> becomes an action edge bound
    # to [self]; help_<spec>/args_<spec> supply optional metadata. Returns the
    # commands dict ready to embed in a state definition.
    method BuildCommands {} {
        set cmds {}
        set methods [info object methods [self] -all]
        set has_quit 0
        set quit_conflicts {}
        foreach m $methods {
            if {![string match "do_*" $m]} continue
            set spec [string range $m 3 end]
            set help ""
            set argspec {}
            if {"help_$spec" in $methods} { set help    [my help_$spec] }
            if {"args_$spec" in $methods} { set argspec [my args_$spec] }
            dict set cmds $spec [list \
                action [list [self] $m] \
                args   $argspec \
                help   $help]
            lassign [my ParseSpec $spec] req opt
            set full $req$opt
            if {$full eq "quit"} { set has_quit 1 }
            # B3: if the required prefix is itself a non-empty prefix of
            # "quit", an auto-injected q(uit) would be ambiguous with this
            # spec — typing those required chars would match both. The
            # user-defined spec resolving to full "quit" suppresses the
            # auto-inject (and so this list), which is why "quit" itself
            # isn't in the set below.
            if {$req in {q qu qui}} { lappend quit_conflicts $spec }
        }
        if {!$has_quit && [llength $quit_conflicts] > 0} {
            error "cmdgraph::Shell: auto-injected q(uit) would be ambiguous\
                   with [join $quit_conflicts {, }]; define a do_q(uit)\
                   (or any do_<spec> whose full text is \"quit\") to opt\
                   out of auto-injection"
        }
        if {!$has_quit} {
            dict set cmds q(uit) [list quit help "exit the shell"]
        }
        return $cmds
    }

    method ParseSpec {spec} {
        if {[regexp {^([^(]+)\(([^)]*)\)$} $spec _ req opt]} {
            return [list $req $opt]
        }
        return [list $spec ""]
    }

    # Public: terminate the cmdloop after the current iteration. Useful from
    # a user-defined do_q(uit) (which is an action, not a quit edge) — call
    # `my exit` once side-effects are done. Hooks may call it too.
    method exit {} { set exiting 1 }

    # Convenience: write to the shell's out_chan (which set_io_channels can
    # redirect). Action methods should prefer `my puts` over bare `puts` so
    # they cooperate with channel redirection and the test harness.
    method puts {args} {
        switch [llength $args] {
            1 { ::puts $out_chan [lindex $args 0] }
            2 {
                if {[lindex $args 0] eq "-nonewline"} {
                    ::puts -nonewline $out_chan [lindex $args 1]
                } else {
                    error "cmdgraph::Shell puts: expected ?-nonewline? string"
                }
            }
            default {
                error "cmdgraph::Shell puts: expected ?-nonewline? string"
            }
        }
    }

    # Redirect channels. Forwards to the engine so its emit_* methods follow.
    method set_io_channels {in out err} {
        set in_chan  $in
        set out_chan $out
        $engine set_io_channels $in $out $err
    }

    # Expose the underlying engine for callers that need direct access
    # (e.g. for state_path, last_error, available_commands).
    method engine {} { return $engine }

    method cmdloop {} {
        # Detect the optional hooks ONCE per cmdloop entry - the previous
        # per-line [info object methods -all] walk (twice per input line) was
        # pure overhead. Hooks defined before cmdloop starts are honoured.
        set methods [info object methods [self] -all]
        set has_precmd  [expr {"precmd"  in $methods}]
        set has_postcmd [expr {"postcmd" in $methods}]
        if {"preloop" in $methods} { my preloop }
        set first 1
        set ok 1
        try {
            while {!$exiting && [$engine is_running]} {
                # Route prompt through the engine so the "out_chan eq {}
                # means suppressed" convention is honoured here just as
                # for engine-emitted output; bypassing it with a bare
                # `puts` would raise on a suppressed channel.
                $engine emit_prompt $prompt_str
                if {[::cmdgraph::encoding::gets $in_chan line enc $first] < 0} break
                set first 0
                if {![::cmdgraph::encoding::supported $enc]} {
                    $engine emit_error [::cmdgraph::encoding::message $enc]
                    set ok 0
                    break
                }
                if {$has_precmd} { set line [my precmd $line] }
                if {$line eq ""} { continue }
                set rc [$engine dispatch $line]
                if {$has_postcmd} { my postcmd $rc $line }
            }
        } finally {
            if {"postloop" in $methods} { my postloop }
        }
        return $ok
    }
}

package provide cmdgraph 1.4.0
