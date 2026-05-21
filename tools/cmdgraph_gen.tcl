#!/usr/bin/env tclsh
# cmdgraph_gen.tcl — generate builder code from a .cgl graph definition
# kate: syntax Tcl/Tk;
#
# Usage: tclsh cmdgraph_gen.tcl <file.cgl> <tcl|fortran|cpp>
# Output goes to stdout; redirect to save.

#── In-memory representation ──────────────────────────────────────────────────
# States and abstracts are stored in declaration order.
# Each state:  dict {prompt on_enter includes commands}
# Each cmd:    dict {edge target proc help args}
# Each arg:    dict {name kind optional count}

namespace eval ::cgl {
    variable initial   {}
    variable order     {}   ;# concrete state names, declaration order
    variable abs_order {}   ;# abstract state names, declaration order
    variable states    {}   ;# dict: name -> state-dict
    variable abstracts {}   ;# dict: name -> abstract-dict
    variable cur_name  {}
    variable cur_type  {}   ;# state | abstract
}

#── DSL: top-level ────────────────────────────────────────────────────────────

namespace eval ::dsl {

    proc initial {name} {
        set ::cgl::initial $name
    }

    proc state {name body} {
        lappend ::cgl::order $name
        dict set ::cgl::states $name [dict create \
            prompt   {} \
            on_enter {} \
            includes {} \
            commands {}]
        set ::cgl::cur_name $name
        set ::cgl::cur_type state
        namespace eval ::dsl::ctx $body
    }

    proc abstract {name body} {
        lappend ::cgl::abs_order $name
        dict set ::cgl::abstracts $name [dict create commands {}]
        set ::cgl::cur_name $name
        set ::cgl::cur_type abstract
        namespace eval ::dsl::ctx $body
    }
}

#── DSL: inside a state or abstract body ──────────────────────────────────────

namespace eval ::dsl::ctx {

    proc prompt {text} {
        set n $::cgl::cur_name
        set d [dict get $::cgl::states $n]
        dict set d prompt $text
        dict set ::cgl::states $n $d
    }

    proc on_enter {proc_name} {
        set n $::cgl::cur_name
        set d [dict get $::cgl::states $n]
        dict set d on_enter $proc_name
        dict set ::cgl::states $n $d
    }

    proc include {abs_name} {
        set n $::cgl::cur_name
        set d [dict get $::cgl::states $n]
        set inc [dict get $d includes]
        lappend inc $abs_name
        dict set d includes $inc
        dict set ::cgl::states $n $d
    }

    proc command {spec args} {
        set edge [lindex $args 0]
        set pos  1
        set c_target {}
        set c_proc   {}

        switch -- $edge {
            action  { set c_proc   [lindex $args $pos]; incr pos }
            goto    { set c_target [lindex $args $pos]; incr pos }
            do_goto { set c_target [lindex $args $pos]; incr pos
                      set c_proc   [lindex $args $pos]; incr pos }
            pop     {}
            do_pop  { set c_proc   [lindex $args $pos]; incr pos }
            quit    {}
            default { error "cmdgraph_gen: unknown edge '$edge' in command {$spec}" }
        }

        set rest   [lrange $args $pos end]
        set c_help {}
        set c_args {}

        # Trailing body block — identified by embedded newlines
        if {[llength $rest] > 0 && [string match "*\n*" [lindex $rest end]]} {
            set c_args [::parse_arg_block [lindex $rest end]]
            set rest   [lrange $rest 0 end-1]
        }

        # Optional help keyword
        if {[llength $rest] >= 2 && [lindex $rest 0] eq "help"} {
            set c_help [lindex $rest 1]
        }

        set cmd [dict create \
            edge   $edge     \
            target $c_target \
            proc   $c_proc   \
            help   $c_help   \
            args   $c_args]

        set n $::cgl::cur_name
        if {$::cgl::cur_type eq "state"} {
            set d [dict get $::cgl::states $n]
            set cmds [dict get $d commands]
            lappend cmds $spec $cmd
            dict set d commands $cmds
            dict set ::cgl::states $n $d
        } else {
            set d [dict get $::cgl::abstracts $n]
            set cmds [dict get $d commands]
            lappend cmds $spec $cmd
            dict set d commands $cmds
            dict set ::cgl::abstracts $n $d
        }
    }
}

#── Arg block parser ──────────────────────────────────────────────────────────
# Each non-blank, non-comment line: arg <name> <kind> [optional|<count>]

proc parse_arg_block {body} {
    set result {}
    foreach line [split $body \n] {
        set line [string trim $line]
        if {$line eq {} || [string index $line 0] eq {#}} continue
        if {[lindex $line 0] eq {arg}} {
            set name  [lindex $line 1]
            set kind  [lindex $line 2]
            set opt   0
            set count 1
            set extra [lindex $line 3]
            if {$extra eq {optional}} {
                set opt 1
            } elseif {$extra ne {} && [string is integer -strict $extra]} {
                set count $extra
            }
            lappend result [dict create name $name kind $kind optional $opt count $count]
        }
    }
    return $result
}

#── Load ──────────────────────────────────────────────────────────────────────

proc load_cgl {filename} {
    namespace eval ::dsl [list source $filename]
    if {$::cgl::initial eq {}} {
        error "no 'initial' declaration in $filename"
    }
    if {![dict exists $::cgl::states $::cgl::initial]} {
        error "'initial' state '$::cgl::initial' not defined"
    }
}

#── Helpers ───────────────────────────────────────────────────────────────────

proc collect_procs {} {
    set procs {}
    foreach name $::cgl::order {
        set d [dict get $::cgl::states $name]
        if {[dict get $d on_enter] ne {}} { lappend procs [dict get $d on_enter] }
        dict for {spec cmd} [dict get $d commands] {
            set p [dict get $cmd proc]
            if {$p ne {}} { lappend procs $p }
        }
    }
    foreach name $::cgl::abs_order {
        set d [dict get $::cgl::abstracts $name]
        dict for {spec cmd} [dict get $d commands] {
            set p [dict get $cmd proc]
            if {$p ne {}} { lappend procs $p }
        }
    }
    set seen {}; set out {}
    foreach p $procs {
        if {$p ni $seen} { lappend seen $p; lappend out $p }
    }
    return $out
}

proc collect_on_enters {} {
    set result {}
    foreach name $::cgl::order {
        set oe [dict get [dict get $::cgl::states $name] on_enter]
        if {$oe ne {} && $oe ni $result} { lappend result $oe }
    }
    return $result
}

proc collect_action_procs {} {
    set on_enters [collect_on_enters]
    set result {}
    foreach p [collect_procs] {
        if {$p ni $on_enters} { lappend result $p }
    }
    return $result
}

#── Emit: Fortran ─────────────────────────────────────────────────────────────

proc fortran_arg {adict} {
    set name  [dict get $adict name]
    set kind  [dict get $adict kind]
    set opt   [dict get $adict optional]
    set count [dict get $adict count]
    if {$count > 1} {
        set fn [dict get {int arg_int_n real arg_real_n} $kind]
        return "${fn}(\"${name}\", ${count})"
    }
    set fn [dict get {int arg_is_int real arg_is_real char arg_is_char rest arg_is_rest} $kind]
    if {$opt} { return "${fn}(\"${name}\", optional=.true.)" }
    return "${fn}(\"${name}\")"
}

proc fortran_args_str {args_list} {
    set parts {}
    foreach a $args_list { lappend parts [fortran_arg $a] }
    return [join $parts ", "]
}

proc fortran_emit_cmd {state_name spec cmd} {
    set edge   [dict get $cmd edge]
    set target [dict get $cmd target]
    set proc_  [dict get $cmd proc]
    set help   [dict get $cmd help]
    set aargs  [dict get $cmd args]

    set ek [dict get {
        action  EDGE_ACTION
        goto    EDGE_GOTO
        do_goto EDGE_DO_GOTO
        pop     EDGE_POP
        do_pop  EDGE_DO_POP
        quit    EDGE_QUIT
    } $edge]

    set opts {}
    if {$target ne {}} { lappend opts "target=\"${target}\"" }
    if {$proc_  ne {}} { lappend opts "proc=${proc_}" }
    if {$help   ne {}} { lappend opts "help=\"${help}\"" }
    if {[llength $aargs] > 0} {
        lappend opts "args=\[[fortran_args_str $aargs]\]"
    }

    set base "    call eng%add_command(\"${state_name}\", \"${spec}\", ${ek}"
    if {[llength $opts] == 0} {
        puts "${base})"
        return
    }
    set kw [join $opts ", "]
    set full "${base}, ${kw})"
    if {[string length $full] <= 100} {
        puts $full
    } else {
        puts "${base}, &"
        puts "        ${kw})"
    }
}

# Sanitise a .cgl basename into a valid Fortran identifier.
proc fortran_ident {basename} {
    set m [regsub -all {[^A-Za-z0-9_]} $basename _]
    if {![string is alpha -strict [string index $m 0]]} { set m "g_$m" }
    return $m
}

proc fortran_modname {basename} {
    return "[fortran_ident $basename]_actions"
}

proc emit_fortran {basename} {
    set action_procs [collect_action_procs]
    set on_enters    [collect_on_enters]
    set has_procs [expr {[llength $action_procs] + [llength $on_enters] > 0}]
    set modname   [fortran_modname $basename]

    puts "! Generated by cmdgraph_gen.tcl from ${basename}.cgl"
    puts "! Stub procedure bodies are starting points -- implement them."
    puts {}

    if {$has_procs} {
        puts "module ${modname}"
        puts "    use cmdgraph"
        puts "    use dlist"
        puts "    implicit none"
        puts {}
        puts "contains"
        foreach p $action_procs {
            puts {}
            puts "    function ${p}(args, ctx) result(rv)"
            puts "        type(dlist_t),    intent(in) :: args"
            puts "        character(len=*), intent(in) :: ctx"
            puts "        type(action_result_t)        :: rv"
            puts "        ! TODO: implement ${p} -- `args` holds parsed arguments,"
            puts "        !       `ctx` the current state context."
            puts "        write(*,'(a,i0,2a)') \"${p} stub: \", args%size(), \" arg(s), ctx=\", ctx"
            puts "        rv = action_ok()"
            puts "    end function ${p}"
        }
        foreach p $on_enters {
            puts {}
            puts "    subroutine ${p}(ctx)"
            puts "        character(len=*), intent(in) :: ctx"
            puts "        ! TODO: implement ${p} -- `ctx` is the context of the entered state."
            puts "        write(*,'(2a)') \"${p} stub: entered, ctx=\", ctx"
            puts "    end subroutine ${p}"
        }
        puts {}
        puts "end module ${modname}"
        puts {}
    }

    puts "subroutine build_graph(eng, stat, errmsg)"
    puts "    use cmdgraph"
    if {$has_procs} { puts "    use ${modname}" }
    puts "    implicit none"
    puts "    type(engine_t),   intent(inout)                            :: eng"
    puts "    integer,          intent(out), optional                    :: stat"
    puts "    character(len=:), allocatable, intent(out), optional       :: errmsg"
    puts {}

    foreach name $::cgl::order {
        set d [dict get $::cgl::states $name]
        set prompt   [dict get $d prompt]
        set on_enter [dict get $d on_enter]
        set includes [dict get $d includes]
        set commands [dict get $d commands]

        if {$prompt ne {}} {
            puts "    call eng%add_state(\"${name}\", prompt=\"${prompt}\")"
        } else {
            puts "    call eng%add_state(\"${name}\")"
        }
        if {$on_enter ne {}} {
            puts "    call eng%set_on_enter(\"${name}\", ${on_enter})"
        }
        foreach inc $includes {
            puts "    call eng%add_include(\"${name}\", \"${inc}\")"
        }
        dict for {spec cmd} $commands {
            fortran_emit_cmd $name $spec $cmd
        }
        puts {}
    }

    foreach name $::cgl::abs_order {
        set d        [dict get $::cgl::abstracts $name]
        set commands [dict get $d commands]
        puts "    call eng%add_state(\"${name}\")"
        dict for {spec cmd} $commands {
            fortran_emit_cmd $name $spec $cmd
        }
        puts {}
    }

    puts "    call eng%finalize(\"$::cgl::initial\", stat=stat, errmsg=errmsg)"
    puts "end subroutine build_graph"

    set prog "[fortran_ident $basename]_main"
    puts {}
    puts "! ── Uncomment for a standalone REPL ──────────────────────────────────────────"
    puts "! program ${prog}"
    puts "!     use cmdgraph"
    puts "!     implicit none"
    puts "!     interface"
    puts "!         subroutine build_graph(eng, stat, errmsg)"
    puts "!             use cmdgraph"
    puts "!             type(engine_t),   intent(inout)                      :: eng"
    puts "!             integer,          intent(out), optional              :: stat"
    puts "!             character(len=:), allocatable, intent(out), optional :: errmsg"
    puts "!         end subroutine build_graph"
    puts "!     end interface"
    puts "!     type(engine_t)                :: eng"
    puts "!     integer                       :: stat"
    puts "!     character(len=:), allocatable :: errmsg"
    puts "!"
    puts "!     call build_graph(eng, stat, errmsg)"
    puts "!     if (stat /= 0) then"
    puts "!         write(*,'(2a)') \"graph error: \", errmsg"
    puts "!         stop 1"
    puts "!     end if"
    puts "!     call eng%run()"
    puts "! end program ${prog}"
}

#── Emit: C++ ─────────────────────────────────────────────────────────────────

proc cpp_arg {adict} {
    set name  [dict get $adict name]
    set kind  [dict get $adict kind]
    set opt   [dict get $adict optional]
    set count [dict get $adict count]
    set fn [dict get {int arg_is_int real arg_is_real char arg_is_char rest arg_is_rest} $kind]
    if {$count > 1} {
        # Expand inline so the initializer list stays clean
        set parts {}
        for {set i 0} {$i < $count} {incr i} {
            lappend parts "cmdgraph::${fn}(\"${name}\")"
        }
        return [join $parts ", "]
    }
    if {$opt} { return "cmdgraph::${fn}(\"${name}\", true)" }
    return "cmdgraph::${fn}(\"${name}\")"
}

proc cpp_args_str {args_list} {
    set parts {}
    foreach a $args_list { lappend parts [cpp_arg $a] }
    return [join $parts ", "]
}

proc cpp_emit_cmd {state_name spec cmd} {
    set edge   [dict get $cmd edge]
    set target [dict get $cmd target]
    set proc_  [dict get $cmd proc]
    set help   [dict get $cmd help]
    set aargs  [dict get $cmd args]

    set ek [dict get {
        action  Action
        goto    Goto
        do_goto DoGoto
        pop     Pop
        do_pop  DoPop
        quit    Quit
    } $edge]

    set opts {}
    if {$target ne {}} { lappend opts ".target = \"${target}\"" }
    if {$proc_  ne {}} { lappend opts ".proc = ${proc_}" }
    if {$help   ne {}} { lappend opts ".help = \"${help}\"" }
    if {[llength $aargs] > 0} {
        lappend opts ".args = {[cpp_args_str $aargs]}"
    }

    set prefix "    eng.add_command(\"${state_name}\", \"${spec}\", cmdgraph::EdgeKind::${ek}"
    if {[llength $opts] == 0} {
        puts "${prefix});"
        return
    }
    if {[llength $opts] == 1} {
        puts "${prefix}, {[lindex $opts 0]});"
        return
    }
    puts "${prefix}, \{"
    set last [expr {[llength $opts] - 1}]
    for {set i 0} {$i <= $last} {incr i} {
        if {$i < $last} {
            puts "        [lindex $opts $i],"
        } else {
            puts "        [lindex $opts $i]\});"
        }
    }
}

proc emit_cpp {basename} {
    set action_procs [collect_action_procs]
    set on_enters    [collect_on_enters]

    puts "// Generated by cmdgraph_gen.tcl from ${basename}.cgl"
    puts "// Stub function bodies are starting points -- implement them."
    puts "#include \"cmdgraph.hxx\""
    puts {}
    foreach p $action_procs {
        puts "cmdgraph::ActionResult ${p}(\[\[maybe_unused\]\] const cmdgraph::ArgList& args, \[\[maybe_unused\]\] const std::string& ctx)"
        puts "{"
        puts "    // TODO: implement ${p}"
        puts "    return {};"
        puts "}"
        puts {}
    }
    foreach p $on_enters {
        puts "void ${p}(\[\[maybe_unused\]\] const std::string& ctx)"
        puts "{"
        puts "    // TODO: implement ${p}"
        puts "}"
        puts {}
    }
    puts "void build_graph(cmdgraph::Engine& eng)"
    puts "{"

    foreach name $::cgl::order {
        set d [dict get $::cgl::states $name]
        set prompt   [dict get $d prompt]
        set on_enter [dict get $d on_enter]
        set includes [dict get $d includes]
        set commands [dict get $d commands]

        if {$prompt ne {}} {
            puts "    eng.add_state(\"${name}\", \"${prompt}\");"
        } else {
            puts "    eng.add_state(\"${name}\");"
        }
        if {$on_enter ne {}} {
            puts "    eng.set_on_enter(\"${name}\", ${on_enter});"
        }
        foreach inc $includes {
            puts "    eng.add_include(\"${name}\", \"${inc}\");"
        }
        dict for {spec cmd} $commands {
            cpp_emit_cmd $name $spec $cmd
        }
        puts {}
    }

    foreach name $::cgl::abs_order {
        set d        [dict get $::cgl::abstracts $name]
        set commands [dict get $d commands]
        puts "    eng.add_state(\"${name}\");"
        dict for {spec cmd} $commands {
            cpp_emit_cmd $name $spec $cmd
        }
        puts {}
    }

    puts "    eng.finalize(\"$::cgl::initial\");"
    puts "}"

    puts {}
    puts "// ── Uncomment for a standalone REPL ──────────────────────────────────────────"
    puts "// int main()"
    puts "// {"
    puts "//     cmdgraph::Engine eng;"
    puts "//     build_graph(eng);"
    puts "//     eng.run();"
    puts "// }"
}

#── Emit: Tcl ─────────────────────────────────────────────────────────────────

# Produce a safe Tcl value for use inside a braced dict literal
proc tcl_val {s} {
    if {$s eq {}} { return {{}} }
    # list gives a properly quoted representation safe anywhere in Tcl source
    return [list $s]
}

proc tcl_edge_dict {cmd} {
    set edge   [dict get $cmd edge]
    set target [dict get $cmd target]
    set proc_  [dict get $cmd proc]
    set help   [dict get $cmd help]
    set aargs  [dict get $cmd args]

    # Order within the edge list mirrors the Tcl engine's parse_edge convention:
    # action proc; goto target; do_goto target proc; pop; do_pop proc; quit
    set parts [list $edge]
    if {$target ne {}} { lappend parts $target }
    if {$proc_  ne {}} { lappend parts $proc_ }

    if {[llength $aargs] > 0} {
        # Build a nested-list representation: {{id int} {name char optional} ...}
        # \{ and \} prevent parse-time brace-counting in the proc body
        set arg_str {}
        foreach a $aargs {
            set aname  [dict get $a name]
            set akind  [dict get $a kind]
            set aopt   [dict get $a optional]
            set acount [dict get $a count]
            for {set i 0} {$i < $acount} {incr i} {
                if {$arg_str ne {}} { append arg_str " " }
                if {$aopt} {
                    append arg_str "\{$aname $akind optional\}"
                } else {
                    append arg_str "\{$aname $akind\}"
                }
            }
        }
        lappend parts "args" "\{$arg_str\}"
    }

    if {$help ne {}} { lappend parts "help" [tcl_val $help] }
    return "{[join $parts { }]}"
}

proc emit_tcl {basename} {
    set action_procs [collect_action_procs]
    set on_enters    [collect_on_enters]

    puts "# Generated by cmdgraph_gen.tcl from ${basename}.cgl"
    puts "# Stub procedure bodies are starting points -- implement them."
    puts {}
    puts "# Uncomment and point at the directory holding cmdgraph-1.1.tm:"
    puts "# ::tcl::tm::path add /path/to/cmdgraph/tcl"
    puts "package require cmdgraph"
    puts {}
    foreach p $action_procs {
        puts "proc ${p} {args} {"
        puts "    # TODO: implement ${p}"
        puts "    return \"\""
        puts "}"
        puts {}
    }
    foreach p $on_enters {
        puts "proc ${p} {} {"
        puts "    # TODO: implement ${p} (context via cmdgraph::context)"
        puts "}"
        puts {}
    }
    puts "proc build_graph {} {"
    puts "    set graph {"

    foreach name [concat $::cgl::order $::cgl::abs_order] {
        if {[dict exists $::cgl::states $name]} {
            set d [dict get $::cgl::states $name]
            set prompt   [dict get $d prompt]
            set on_enter [dict get $d on_enter]
            set includes [dict get $d includes]
            set commands [dict get $d commands]

            puts "        $name {"
            if {$prompt ne {}}   { puts "            prompt   [tcl_val $prompt]" }
            if {$on_enter ne {}} { puts "            on_enter $on_enter" }
            if {[llength $includes] > 0} {
                puts "            includes {$includes}"
            }
            puts "            commands {"
            dict for {spec cmd} $commands {
                puts "                {$spec} [tcl_edge_dict $cmd]"
            }
            puts "            }"
            puts "        }"
        } else {
            set d        [dict get $::cgl::abstracts $name]
            set commands [dict get $d commands]
            puts "        $name {"
            puts "            commands {"
            dict for {spec cmd} $commands {
                puts "                {$spec} [tcl_edge_dict $cmd]"
            }
            puts "            }"
            puts "        }"
        }
    }

    puts "    }"
    puts "    return \[cmdgraph::Engine new \$graph $::cgl::initial\]"
    puts "}"

    puts {}
    puts "# ── Uncomment for a standalone REPL ──────────────────────────────────────────"
    puts "# set eng \[build_graph\]"
    puts "# \$eng run"
}

#── Main ──────────────────────────────────────────────────────────────────────

if {$argc != 2} {
    puts stderr "Usage: tclsh cmdgraph_gen.tcl <file.cgl> <tcl|fortran|cpp>"
    exit 1
}

set cgl_file [lindex $argv 0]
set target   [lindex $argv 1]

if {$target ni {tcl fortran cpp}} {
    puts stderr "Unknown target '$target'; expected tcl, fortran, or cpp"
    exit 1
}

if {[catch {load_cgl $cgl_file} err]} {
    puts stderr "Error loading $cgl_file: $err"
    exit 1
}

set basename [file rootname [file tail $cgl_file]]

switch $target {
    tcl     { emit_tcl     $basename }
    fortran { emit_fortran $basename }
    cpp     { emit_cpp     $basename }
}

exit 0

