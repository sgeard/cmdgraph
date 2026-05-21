# cmdgraph cross-language parity harness

Phase 1 of the strict-parity resolution plan (see memory
`project_cmdgraph_review.md`). Feeds identical scripts through the Tcl,
Fortran and C++ implementations via `run_file` and diffs three observable
channels against a single golden set **and** cross-checks the three impls
against each other.

## Why

The review (2026-05-19) found bugs and drift that survived because there was
no test exercising the same script through all three engines. This harness
is the regression keystone: every later phase ends with it green.

## Canonical graph

All three runners build the **same** small graph by hand (kept minimal so
divergence shows up immediately as a harness failure — the harness is itself
a check on structural drift). The graph and the parity action procs are
specified in `GRAPH.md`. Action procs emit representation-independent fixed
strings only (no floats, no language-internal type introspection) so the
*observable* output is byte-identical by construction; int->real and similar
behaviours are asserted at the engine level (RC / last_message / last_error),
never via the action's internal value type.

## Observable channels compared

For each script the runner produces:

- `*.out` — process stdout (engine info/echo/prompt + parity action prints)
- `*.err` — process stderr (engine error channel)
- `*.res` — normalised structured trailer:
  `ok`, `rc`, `line`, `state`, `last_message`, `last_error`

`rc` is normalised across impls. The open-failure discriminator is the P0
contract: `ok==0 && line==0` -> `rc=OPEN_FAIL` (Tcl `stat open`, Fortran
`stat=-1`, post-P4 C++ all collapse to this).

## Golden = P0 canonical behaviour (TDD)

`golden/` encodes the **agreed post-fix** behaviour, not today's. Running the
harness now is expected to show RED for the known findings:

- C++: comment/blank skip, echo default/content, numeric token, empty
  required rest, open-failure discriminator, unknown/ambiguous channel.
- Tcl: `do_goto` boolean-context trap (`zero` returns `"0"`).
- Fortran: `ambiguous` space-vs-comma format.

Each goes green as its phase lands.

## Run

```
tclsh tools/parity/run.tcl            # all impls it can build
tclsh tools/parity/run.tcl tcl        # restrict to listed impls
```

The driver builds the Fortran/C++ runners via `make` (gfortran/g++ by
default — no special env needed; override with `F=ifx CXX=icpx`). Exit code
is non-zero if any impl mismatches golden.
