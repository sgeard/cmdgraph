# kate: syntax Tcl/Tk;

# demo_shell.tcl — a tiny accumulator calculator built with cmdgraph::Shell.
#
# Run interactively:
#   tclsh demo_shell.tcl
#
# Or with scripted input:
#   tclsh demo_shell.tcl <<EOF
#   help
#   add 10
#   mul 4
#   print
#   EOF
#
# What this demonstrates:
#   - Subclass cmdgraph::Shell, write `do_<spec>` instance methods.
#   - Per-command typed arg specs via `args_<spec>` — the engine validates
#     before the method runs, so the method body is pure logic.
#   - Per-command help text via `help_<spec>` — picked up by the built-in
#     `help` / `?` command and column-aligned with the spec.
#   - Lifecycle hooks `preloop` / `postloop`.
#   - Auto-injected `q(uit)` — Calc does not define one, so the base class
#     adds a real `quit`-kind edge.
#   - `my puts` routes output through the shell's configurable out_chan
#     (defaults to stdout); using bare `puts` would bypass any
#     `set_io_channels` redirection.
#
# All four lifecycle hooks (preloop, postloop, precmd, postcmd) are
# honoured iff defined; this demo uses preloop and postloop. See
# utest_shell.tcl for working examples of precmd / postcmd.

tcl::tm::path add [file dirname [info script]]
package require cmdgraph

oo::class create Calc {
    superclass cmdgraph::Shell

    variable acc

    constructor {} {
        next "calc> "
        set acc 0
    }

    # ── commands ──────────────────────────────────────────────────────────

    method do_a(dd)   {x} { set acc [expr {$acc + $x}]; my puts "= $acc" }
    method args_a(dd) {}  { return {{x real}} }
    method help_a(dd) {}  { return "Add x to the accumulator" }

    method do_s(ubtract)   {x} { set acc [expr {$acc - $x}]; my puts "= $acc" }
    method args_s(ubtract) {}  { return {{x real}} }
    method help_s(ubtract) {}  { return "Subtract x from the accumulator" }

    method do_m(ultiply)   {x} { set acc [expr {$acc * $x}]; my puts "= $acc" }
    method args_m(ultiply) {}  { return {{x real}} }
    method help_m(ultiply) {}  { return "Multiply the accumulator by x" }

    method do_r(eset)   {} { set acc 0; my puts "reset" }
    method help_r(eset) {} { return "Reset the accumulator to 0" }

    method do_p(rint)   {} { my puts "acc = $acc" }
    method help_p(rint) {} { return "Print the accumulator" }

    # ── lifecycle hooks ───────────────────────────────────────────────────

    method preloop  {} { my puts "(calc demo — type 'help' for commands)" }
    method postloop {} { my puts "(bye, final acc = $acc)" }
}

[Calc new] cmdloop
