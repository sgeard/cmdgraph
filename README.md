# cmdgraph

## Introduction
This work was inspired by my recollection of the technology we use when
building a 2d drafting system in the 1980's. The way we used it then was
to define the menu system on a test file (see Graph definition language)
and generate source code from that. Once the pro-forma source had between
generated we just worked with that and didn't go back to the text file.

The command graph is fixed at startup, it can't be edited once finalized.
This also means that the whole graph is loaded rather than just the part
that's in use.

`cmdgraph` is a state-graph driven command interpreter — a parsing and
dispatch kernel for building interactive command shells and REPL-style
workflows. It is best understood as a pushdown transducer: a finite state
graph on a runtime stack, where each transition can invoke an action and
carry an opaque context value into the new state.

Parsing is decoupled from behaviour. The same engine drives any application
by feeding it a different graph; the application supplies only the action
procedures.

Three implementations are kept in parity:

- **`tcl/cmdgraph-1.1.tm`** — reference implementation (Tcl 8.6+, TclOO)
- **`fortran/`** — Fortran port (Fortran 2018, module/submodule structure)
- **`cpp/`** — C++ port (C++23, single header + implementation file)

---

## Concept

A graph is a collection of **states**, each with a set of **commands**.
Commands match by required and optional prefix, e.g. `s(elect)` means any of `s`,
`se`, `sel`, … `select` will match. When a command is typed, the engine looks
up the current state's command set, validates any declared argument types, and
fires the associated edge.

**Edges** determine what happens next: stay in place, push a new state onto
the runtime stack, pop back to the previous state, or exit. The stack is the
"memory" of where you came from — every `pop` undoes the most recent push, so
navigation naturally forms a tree. The optional **context** string rides with
each stack frame; a `do_goto` action sets it, and every action in that state
can read it to find out what the state is operating on (a book id, a filename,
a record key).

---

## Quick start

### Tcl

```tcl
package require cmdgraph

proc act_list {args} {
    puts "1  The Pragmatic Programmer"
    puts "2  SICP"
}

# Return the id (any non-empty string) to transition; return "" to stay
proc act_open {args} {
    set id [lindex $args 0]
    if {$id < 1 || $id > 2} { puts "no such book"; return "" }
    return $id
}

proc act_summary {args} {
    # cmdgraph::context returns the context of the current state
    puts "Summary for book [cmdgraph::context]"
}

set graph {
    library {
        prompt "library> "
        commands {
            l(ist) {action  act_list                     help "list books"}
            o(pen) {do_goto book   act_open  args {{id int}}
                                             help "open book by id"}
            q(uit) {quit                     help "exit"}
        }
    }
    book {
        prompt "book> "
        commands {
            s(ummary) {action act_summary    help "show summary"}
            b(ack)    {pop                   help "back to library"}
            q(uit)    {quit                  help "exit"}
        }
    }
}

cmdgraph::Engine create repl $graph library
repl run
```

### Fortran

The Fortran API uses a builder: call `add_state` / `add_command` then
`finalize` before `run`. Action procedures have the fixed signature
`function(args, ctx) result(rv)` where `args` is a typed linked list and `ctx`
is the current context string.

```fortran
use cmdgraph
use dlist

type(engine_t) :: eng

call eng%add_state("library", prompt="library> ")
call eng%add_command("library", "l(ist)",  EDGE_ACTION,                           &
                     proc=act_list,  help="List books")
call eng%add_command("library", "o(pen)",  EDGE_DO_GOTO, target="book",           &
                     proc=act_open,  help="Open book by id", args=[arg_is_int("id")])
call eng%add_command("library", "q(uit)",  EDGE_QUIT,    help="Exit")

call eng%add_state("book", prompt="book> ")
call eng%add_command("book", "s(ummary)", EDGE_ACTION, proc=act_summary, help="Show summary")
call eng%add_command("book", "b(ack)",    EDGE_POP,    help="Back to library")
call eng%add_command("book", "q(uit)",    EDGE_QUIT,   help="Exit")

call eng%finalize("library")
call eng%run()
```

Action procedures return `action_result_t` via the named constructors:

```fortran
function act_open(args, ctx) result(rv)
    type(dlist_t), intent(in)    :: args
    character(len=*), intent(in) :: ctx
    type(action_result_t)        :: rv
    class(dlist_node_data_t), allocatable :: n
    integer :: id
    character(len=16) :: buf

    n = args%get(1)
    select type (n)
    type is (dlist_node_integer)
        id = n%data
        if (id < 1 .or. id > 2) then
            rv = action_error("no such book")  ! RC_ERROR, message → last_error
            return
        end if
        write(buf,'(i0)') id
        rv = action_ok(trim(buf))  ! truthy value → push "book" with this context
    end select
end function act_open
```

Complete working examples are in [`fortran/app/main.f90`](fortran/app/main.f90)
(library REPL) and [`fortran/cad_2d/cad_2d.f90`](fortran/cad_2d/cad_2d.f90)
(simple 2D CAD).

### C++

The C++ API mirrors the Fortran builder style. Include `cmdgraph.hxx`, link
`libcmdgraph.a`, and use the `cmdgraph::` namespace. Action procedures are
`std::function<ActionResult(const ArgList&, const std::string&)>` — lambdas
and free functions both work.

```cpp
#include "cmdgraph.hxx"
using namespace cmdgraph;

Engine ui;

ui.add_state("library", "library> ");
ui.add_command("library", "l(ist)",  EdgeKind::Action,
               {.proc=act_list, .help="List books"});
ui.add_command("library", "o(pen)",  EdgeKind::DoGoto,
               {.target="book", .proc=act_open,
                .help="Open book by id", .args={arg_is_int("id")}});
ui.add_command("library", "q(uit)",  EdgeKind::Quit, {.help="Exit"});

ui.add_state("book", "book> ");
ui.add_command("book", "s(ummary)", EdgeKind::Action,
               {.proc=act_summary, .help="Show summary"});
ui.add_command("book", "b(ack)",    EdgeKind::Pop,  {.help="Back to library"});
ui.add_command("book", "q(uit)",    EdgeKind::Quit, {.help="Exit"});

ui.finalize("library");
ui.run();
```

Action procedures return `ActionResult` via the named constructors:

```cpp
ActionResult act_open(const ArgList& args, const std::string&) {
    int id = arg_int(args[0]);   // engine validated ARG_INT
    if (id < 1 || id > 2)
        return action_error("no such book");
    return action_ok(std::to_string(id));  // value → push "book" with id as context
}
```

Complete working examples are in [`cpp/app/main.cxx`](cpp/app/main.cxx)
(library REPL) and [`cpp/cad_2d/cad_2d.cxx`](cpp/cad_2d/cad_2d.cxx)
(simple 2D CAD).

---

## Graph definition language

For non-trivial graphs, writing the builder calls by hand becomes repetitive.
`tools/cmdgraph_gen.tcl` reads a `.cgl` file and emits a ready-to-use builder
function for any of the three targets.

```bash
tclsh tools/cmdgraph_gen.tcl myapp.cgl tcl      > myapp_graph.tcl
tclsh tools/cmdgraph_gen.tcl myapp.cgl fortran   > build_graph.f90
tclsh tools/cmdgraph_gen.tcl myapp.cgl cpp       > build_graph.cxx
```

A `.cgl` file is valid Tcl evaluated in a controlled namespace, so standard Tcl
comments (`#`) work and no separate parser is needed. The generator emits a
single builder procedure — `proc build_graph {}` (Tcl),
`subroutine build_graph(eng, stat, errmsg)` (Fortran), or
`void build_graph(cmdgraph::Engine&)` (C++) — plus a list of TODO stubs for
the action procedures that still need to be written.

### .cgl syntax

```tcl
initial <state>

state <name> {
    prompt   "..."
    on_enter <proc>
    include  <abstract>

    command {spec} action   <proc>                   [help "..."] [{ arg ... }]
    command {spec} goto     <target>                 [help "..."]
    command {spec} do_goto  <target> <proc>          [help "..."] [{ arg ... }]
    command {spec} pop                               [help "..."]
    command {spec} do_pop   <proc>                   [help "..."] [{ arg ... }]
    command {spec} quit                              [help "..."]
}

abstract <name> {
    command ...
}
```

Argument blocks inside `{ }` after a command:

```tcl
arg <name> int|real|char|rest [optional]
arg <name> int|real            <count>    # fixed-N shorthand, e.g. arg pt real 2
```

A complete example is in [`tools/example.cgl`](tools/example.cgl).

---

## Reference

### Edge kinds

| Fortran constant | C++ enum             | Tcl keyword | Behaviour |
|-----------------|----------------------|-------------|-----------|
| `EDGE_ACTION`   | `EdgeKind::Action`   | `action`    | Invoke proc, stay in current state |
| `EDGE_GOTO`     | `EdgeKind::Goto`     | `goto`      | Push target state (no proc call) |
| `EDGE_DO_GOTO`  | `EdgeKind::DoGoto`   | `do_goto`   | Invoke proc; non-empty return pushes target with return value as context (`""` stays) |
| `EDGE_POP`      | `EdgeKind::Pop`      | `pop`       | Pop the stack (back / esc) |
| `EDGE_DO_POP`   | `EdgeKind::DoPop`    | `do_pop`    | Invoke proc, then pop on success (commit-and-return) |
| `EDGE_QUIT`     | `EdgeKind::Quit`     | `quit`      | Exit the engine |

### Arg specs

Declare per-command argument specs to have the engine validate count and
types before the action is called. Help text automatically renders the specs.

**Fortran** — pass an array of `arg_spec_t` values as the `args=` keyword:

```fortran
! individual specs
args=[arg_is_int("id")]
args=[arg_is_real("x"), arg_is_real("y")]
args=[arg_is_char("label"), arg_is_int("count", optional=.true.)]
args=[arg_is_rest("message")]          ! captures remainder of line verbatim

! fixed-N helpers (returns an array of n identical specs)
args=arg_real_n("pt", 3)              ! <pt:real> <pt:real> <pt:real>
args=[arg_int_n("n", 2), arg_is_char("name")]
```

**C++** — pass a `std::vector<ArgSpec>` as the `args` field of `CommandOptions`:

```cpp
// individual specs
.args={arg_is_int("id")}
.args={arg_is_real("x"), arg_is_real("y")}
.args={arg_is_char("label"), arg_is_int("count", /*optional=*/true)}
.args={arg_is_rest("message")}         // captures remainder of line verbatim

// fixed-N helpers (return a vector of n identical specs)
.args=arg_real_n("pt", 3)             // <pt:real> <pt:real> <pt:real>
```

**Tcl** — inline in the command definition:

```tcl
args {{id int}}
args {{x real} {y real}}
args {{label char} {count int optional}}
args {{message rest}}
args [cmdgraph::arg_real_n pt 3]
```

Spec kinds:

| Kind | Fortran / C++ constructor | Tcl | Accepts |
|------|--------------------------|-----|---------|
| Integer | `arg_is_int` | `int` | integer token |
| Real | `arg_is_real` | `real` | floating-point token |
| Character | `arg_is_char` | `char` | word or quoted string |
| Rest | `arg_is_rest` | `rest` | verbatim remainder of the line (must be last) |

Trailing specs may be marked optional. The engine rejects commands that
receive too few required args or too many args of the wrong type, and reports
the failure via the error channel before the action is ever called.

### Action results

**Fortran** — actions return `action_result_t`. Use the named constructors:

```fortran
rv = action_ok()           ! success, no transition
rv = action_ok("ctx")      ! success; "ctx" becomes the new state's context (do_goto)
rv = action_error()        ! failure (RC_ERROR), no message
rv = action_error("msg")   ! failure; "msg" → error channel and eng%last_error
```

`action_result_t` has public fields (`errored`, `value`, `errmsg`) for
callers that prefer struct literals, but the constructors are clearer.

**C++** — actions return `ActionResult`. Same named constructors:

```cpp
return action_ok();           // success, no transition
return action_ok("ctx");      // success; "ctx" → context (do_goto)
return action_error();        // failure (RC::Error), no message
return action_error("msg");   // failure; "msg" → error channel and eng.last_error
```

**Tcl** — actions return a plain value:

- For `do_goto`: return any non-empty string to transition (the string becomes
  the new state's context); return `""` to stay. `"0"`, `"no"`, `"false"` are
  valid contexts that DO transition — only the empty string means stay.
- For `do_pop`: any return that does not raise a Tcl error pops successfully;
  raise an error (via `error` or `return -code error …`) to refuse the pop.
- For `action`: return value is ignored.
- Tcl errors are caught as a safety net; `last_error` captures the message.

### Context

Context is an opaque string carried with each stack frame. It is set by the
return value of a `do_goto` action and remains constant until that frame is
popped. Actions read it via:

- Fortran: the `ctx` argument passed to every action proc, or `eng%current_context()`
- Tcl: `cmdgraph::context` (convenience) or `[eng current_context]`

Use context to carry an object identity into a sub-state: an open file, a
selected record, a drawing object. The stack structure means each frame has
its own independent context.

### On-enter hooks

A state may declare a procedure that is called whenever the state is pushed
(by `goto` or a successful `do_goto`). The hook runs after the context is
set, so it can display state-entry information.

```fortran
call eng%set_on_enter("book", enter_book)   ! Fortran

subroutine enter_book(ctx)
    character(len=*), intent(in) :: ctx
    ! ctx is the newly-set context
end subroutine
```

```tcl
# Tcl — declared in the state definition
book {
    prompt   "book> "
    on_enter enter_book_proc
    commands { ... }
}
```

### Includes and abstract states

A state without a `prompt` is **abstract** — it can never be entered directly,
but its command set can be merged into other states via `includes`. This avoids
duplicating common commands (quit, help, style settings) across many states.

```fortran
call eng%add_state("nav_common")              ! no prompt → abstract
call eng%add_command("nav_common", "q(uit)", EDGE_QUIT, help="Exit")

call eng%add_state("home", prompt="> ")
call eng%add_include("home", "nav_common")   ! home inherits quit
```

```tcl
nav_common {
    commands { q(uit) {quit help "Exit"} }
}
home {
    prompt   "> "
    includes {nav_common}
    commands { ... }
}
```

State's own commands take precedence over included ones. Includes are flat:
they do not pull in the includes of the included state.

### Introspection

```fortran
name  = eng%current_state()     ! name of the top-of-stack state
ctx   = eng%current_context()   ! its context string
ok    = eng%is_running()        ! .false. after quit or empty pop
cmds  = eng%available_commands() ! command_info_t(:) for current state
path  = eng%state_path()        ! character(:) array from bottom to top of stack
```

```tcl
eng current_state
eng current_context
eng is_running
eng available_commands   ;# list of dicts: spec req opt kind target args help
eng state_path           ;# list of state names bottom → top
```

`available_commands` is the hook for building a GUI menu or command palette.
The result depends only on the current state name; since the graph is immutable
after construction, callers may cache it keyed by state name.

### Dispatch return codes

`dispatch` is the single-line entry point. `run` calls it in a loop; use
`dispatch` directly for GUI / programmatic callers.

| Fortran constant   | C++ enum value       | Tcl word      | Meaning |
|--------------------|----------------------|---------------|---------|
| `RC_OK`            | `RC::Ok`             | `ok`          | Action ran, do_goto stayed, built-in help, or empty line |
| `RC_UNKNOWN`       | `RC::Unknown`        | `unknown`     | No command matched |
| `RC_AMBIGUOUS`     | `RC::Ambiguous`      | `ambiguous`   | Multiple commands matched |
| `RC_TRANSITIONED`  | `RC::Transitioned`   | `transitioned`| State pushed or popped without exit |
| `RC_EXITED`        | `RC::Exited`         | `exited`      | Quit, pop emptied the stack, or engine already dead |
| `RC_ERROR`         | `RC::Error`          | `error`       | Action returned an error |

The engine also maintains `last_message` (last info output) and `last_error`
(last error message) for callers that intercept output by redirecting the
I/O channels.

---

## Building

### Fortran

Dependencies: `dlist` (included in `fortran/src/`). Primary compiler is `ifx`;
`gfortran` and `flang` are also supported.

```bash
# Build everything (library, tests, demos)
make -C fortran F=ifx

# Run unit tests
./fortran/obj_intel_release/utest_cmdgraph

# With gfortran
make -C fortran F=gfortran
./fortran/obj_gfortran_release/utest_cmdgraph

# With flang
make -C fortran F=flang
```

An `fpm.toml` is provided for projects that prefer fpm, though the Makefile
is the primary build system.

### C++

No external dependencies. Primary compiler is `icx` (Intel oneAPI); `g++` is
also supported.

```bash
# Build everything (library, tests, demos)
make -C cpp CXX=icx

# Run unit tests
./cpp/obj_icx/utest_cmdgraph

# With g++
make -C cpp CXX=g++
./cpp/obj_g++/utest_cmdgraph
```

To use the library in another project: copy `cpp/include/cmdgraph.hxx` and
`cpp/src/cmdgraph.cxx` into your tree, or build `libcmdgraph.a` and point your
compiler at the header directory.

### Tcl

No build step. Add the `tcl/` directory to your Tcl module path and
`package require cmdgraph`. To run the test suite:

```bash
tclsh tcl/utest_cmdgraph.tcl
```

### Documentation

The Fortran API documentation is published at
**<https://sgeard.github.io/cmdgraph/>**.

It is generated with [FORD](https://forddocs.readthedocs.io). To rebuild it
locally and refresh the published site, from the `fortran/` directory:

```bash
ford ford.md                       # regenerate fortran/ford_docs/
bash ../tools/publish-ford-docs    # rebuild the gh-pages branch
```

The C++ header (`cpp/include/cmdgraph.hxx`) carries Doxygen `///` comments on
all public API elements. Point Doxygen at the `cpp/include/` directory with
`EXTRACT_ALL = NO` to produce class and function reference pages.

---

## Design boundary

`cmdgraph` is a **dispatch kernel**, not a terminal framework. It does not
provide readline-style line editing, command history, or tab completion. The
`run` method is a plain `gets` loop: whatever the terminal gives it, it
dispatches. Line editing and history belong in the layer above — a readline
wrapper, a GUI text entry widget, or a script runner — where they can be
chosen to match the deployment environment.

The graph must be a directed acyclic graph on `goto` / `do_goto` edges between
concrete states. `pop` and `do_pop` are the return paths and are not
constrained. `finalize` validates the DAG and rejects cycles.

---

## Performance characteristics

The data structures are intentionally simple: plain arrays with linear scans.
This keeps the code readable and the behaviour predictable; it is the right
trade-off for the expected scale.

**Dispatch** is O(*c*) where *c* is the number of commands in the *current
state* — not the total number of states or commands in the graph. After
`finalize`, state references are resolved to integer indices, so the dispatch
path never searches by name. At human typing speeds, a state with hundreds of
commands would still dispatch in well under a millisecond in the compiled
implementations; in Tcl, proc-call overhead dominates long before the scan
does.

**Construction** uses a linear scan to look up state names
(O(*s*) per call, where *s* is the number of states so far), and O(N) total
for adding N commands to a state (singly-linked list in Fortran;
`std::vector` in C++). Construction is a one-time cost; a graph with thousands
of states and commands builds in milliseconds.

**Memory** is proportional to the total number of commands across all states.
Each command holds a handful of short strings (spec, help, target) and an
optional array of arg-spec structs; a graph with 100 states and 20 commands per
state uses on the order of a few hundred kilobytes.

**Practical limit** — the effective ceiling is usability rather than
performance. Beyond roughly 20–30 commands in a single state, the built-in
`help` output becomes hard to scan. In practice, graphs encountered so far have
had fewer than 15 commands per state and fewer than 20 states in total, and the
engine is imperceptibly fast at that scale in all three implementations.

If you are caching `available_commands()` to drive a GUI menu or command
palette, note that the result depends only on the state name; keying the cache
by state name is safe since the graph is immutable after `finalize`.

Concrete demonstrations are provided for Fortran and C++. Each builds one state
with N=5000 commands (pathological) and one with N=20 (realistic), then times
construction and dispatch. Run with:

```
make -C fortran F=ifx perf
make -C cpp CXX=icpx perf
```

Measured on a Ryzen 9 7950X with ifx/icpx -O3:

**Fortran** (construction O(N) — `add_command` writes into a capacity-doubling
over-allocated `commands(:)`; `finalize` trims to exact count in one step):
```
=== pathological case (N=5000) ===
  construction (add_command x 5000):    0.015 s   [O(N)]
  dispatch x 100000:                   13.685 s   [O(N x D)]

=== realistic case (N=20) ===
  construction (add_command x 20):      0.001 s
  dispatch x 100000:                    0.107 s
```

**C++** (construction O(N) amortised — `std::vector::push_back` doubles capacity as needed):
```
=== pathological case (N=5000) ===
  construction (add_command x 5000):    0.044 s   [O(N) amortised]
  dispatch x 100000:                    8.013 s   [O(N x D)]

=== realistic case (N=20) ===
  construction (add_command x 20):      0.001 s
  dispatch x 100000:                    0.048 s
```

The pathological case is deliberately absurd — 5000 commands in one state would
be unusable regardless of performance. It is included so that the algorithmic
costs are visible rather than theoretical. Both implementations now build in
O(N); the remaining bottleneck is dispatch, which must scan all commands to
detect ambiguity.

---

## Known limitations

**lfortran** — the Fortran implementation does not build with lfortran
(tested up to the current alpha release). The code uses standard Fortran 2018
features (module/submodule, allocatable character, polymorphic types) that are
not yet fully implemented in lfortran.

**No escaped quotes** — the tokeniser does not support `\"` inside a quoted
string. A quoted token must begin and end with `"` and may not contain a
literal `"`. This should be sufficient for the typical command-shell use case.
