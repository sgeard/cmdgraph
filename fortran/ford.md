---
project: cmdgraph
summary: State-graph driven command interpreter — Fortran implementation
author: Simon Geard
project_url:
src_dir: src
output_dir: ford_docs
exclude_dir: build obj_intel_release obj_gfortran_release
dbg: False
---

`cmdgraph` is a parsing and dispatch kernel for building interactive command
shells and REPL-style workflows.  It models the application as a state graph
on a runtime stack: each state has a set of commands; each command fires an
edge that may invoke an action and transition to another state.

Parsing is decoupled from behaviour.  The same engine drives any application
by supplying a different graph; the application supplies only the action
procedures.

## Quick start

```fortran
use cmdgraph
type(engine_t) :: eng

call eng%add_state("root", prompt="> ")
call eng%add_command("root", "q(uit)", EDGE_QUIT, help="exit")
call eng%add_command("root", "s(elect)", EDGE_DO_GOTO, target="detail", &
                     proc=act_select, help="select item <id>", &
                     args=[arg_is_int("id")])
call eng%finalize("root")
call eng%run()
```

## Architecture

| Module | Role |
|--------|------|
| `dlist` | Polymorphic doubly-linked list used as the parsed-argument container |
| `cmdgraph` | Public API — types, constants, `engine_t`, abstract interfaces |
| `cmdgraph_sm` | Submodule containing all implementations (not documented here) |

## Edge kinds

| Constant | Behaviour |
|----------|-----------|
| `EDGE_ACTION`  | Invoke proc, stay in current state |
| `EDGE_GOTO`    | Push target state with empty context (no proc) |
| `EDGE_DO_GOTO` | Invoke proc; non-empty return value pushes target with that value as context |
| `EDGE_POP`     | Pop the stack — the canonical back/esc path (no proc) |
| `EDGE_DO_POP`  | Invoke proc, then pop on success (commit-and-return) |
| `EDGE_QUIT`    | Exit the engine |

## Dispatch return codes

| Constant | Meaning |
|----------|---------|
| `RC_OK`          | Action ran, DoGoto stayed, help shown, or blank line |
| `RC_UNKNOWN`     | No command matched |
| `RC_AMBIGUOUS`   | Multiple commands matched a common prefix |
| `RC_TRANSITIONED`| State changed: Goto pushed, DoGoto succeeded, or Pop returned |
| `RC_EXITED`      | Engine stopped: Quit, stack exhausted, or already dead |
| `RC_ERROR`       | Action returned an error, or arg validation failed |
