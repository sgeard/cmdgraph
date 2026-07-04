# cmdgraph roadmap

cmdgraph is a state-graph driven command interpreter: a parsing and dispatch
engine that decouples a declarative command graph from the actions it invokes.
This document tracks the work needed to make it comfortably usable in
non-demo projects, and — just as importantly — records what is deliberately
**out of scope** so the engine stays focused.

It supersedes the earlier `codex_issues` scratch list, reconciled against the
state of the tree at r1447. Updated 2026-05-16 to reflect the C++ port and
versioning. Further updated 2026-05-20 to record the cross-implementation
parity contract and the harness that enforces it. Further updated 2026-05-21
to record the 1.1.0 release bump that absorbs the Tcl `do_goto` truthiness
behavioural break introduced by that contract. Same day, further updated to
record the 1.2.0 release in the Tcl distribution only — `cmdgraph::Shell`
façade — and the consequent narrowing of the cross-impl major/minor sync rule
to engine semantics. Updated 2026-07-04 to record the 1.3.0 release across all
three implementations — the `swap` / `do_swap` frame-replacing edge pair.

## Guiding principle

The discriminator for every item below is: **is this a parsing/dispatch
concern, or a frontend/app concern?** Parsing and dispatch belong here.
Interactive completion, line editing, and history do not — they belong in the
GUI or a readline-style wrapper. A "make it useful to others" wishlist tends
toward a kitchen-sink CLI framework; this roadmap resists that.

## Already delivered

The original top priorities have largely landed. Do not re-implement these:

- **Quoted / string argument parsing** (r1441). Single delimiter constant
  (`ARG_DELIMITERS` / `arg_delimiters`), quote-aware tokenizer, surrounding
  quotes stripped, unmatched quotes rejected as an error. `validate_args` now
  operates on the parsed argument list, not raw text. The delimiter set was
  later reduced to a single space — tab removed by deliberate decision, since
  non-printable delimiters are undiagnosable.
  *Residual:* no escaped `\"` inside a quoted token. (Rest-of-line capture is
  not a residual — it is High-value item #2 below.)
- **Programmatic diagnostics & I/O hooks** (r1442, extended r1444). All output
  goes through `emit_prompt` / `emit_info` / `emit_error`; engine caches
  `last_message` / `last_error`; output and input are redirectable
  (`set_io_units` in Fortran, `set_io_channels {in out err}` in Tcl);
  `run_file` gained an `echo` flag. The Tcl input-channel asymmetry vs Fortran
  was closed at r1444 (`run` reads a configurable `in_chan`).
  Bug fixed post-help/usage: the Fortran `emit_*` guards used `unit > 0`,
  which silently suppressed output sent to a negative `open(newunit=)`
  file unit (the standard idiom). Now guarded against a documented
  `QUIET_UNIT = -1` sentinel — a value `newunit` can never return — so
  redirecting to a `newunit` file works and explicit suppression is
  unchanged. Tcl unaffected (channel `""` already meant suppressed).
  *Residual:* fixed 4096-char line buffer in the Fortran `run`.
- **Declarative argument specs core** (r1439–r1442). `arg_spec_t` with
  `int` / `real` / `char` kinds and trailing-optional support; strict
  validation between parse and dispatch.
- **Tail-recursion conversion** (r1443–r1444, Tcl). Parser helpers
  (`strip_leading_arg_space`, `count_char`, `parse_args`) converted to
  accumulator + `tailcall` form. Internal hardening; no API change.
- **Introspection API** (r1446). `available_commands` (current state's
  resolved command set) and `state_path`, both impls in parity; new public
  Fortran `command_info_t`, Tcl list-of-dicts with the same keys. Result
  depends only on the current state name (graph immutable post-finalize) so
  callers may cache it. This is the in-scope introspection subset;
  interactive completion remains out (see below).
- **Help / usage generation from arg specs** (r1449, both impls in parity).
  Built-in help now appends each command's arg specs to its spec: required
  args render as `<name:kind>`, optional as `[name:kind]`, kinds
  `int`/`real`/`char` (e.g. `p(air) <id:int> [label:char]`). Commands with
  no specs are unchanged. `command_usage` helper drives both the column-width
  calc and the rendered line; byte-identical across Fortran and Tcl
  (asserted in both test suites).
- **Rest-of-line argument kind** (both impls in parity). A `rest` arg spec
  (`arg_is_rest` / `{name rest ?optional?}`) captures the verbatim unparsed
  remainder as one string: leading delimiter run stripped, internal and
  trailing spaces and quotes preserved, no unquoting. Must be the last spec
  slot — rejected at construction otherwise (Fortran stat/errmsg, Tcl
  `error`). Leading structured args before it are still tokenised, typed and
  quote-checked normally; the unmatched-quote check applies only to that
  leading span, so the rest portion may contain a lone `"` (the point: no
  forced quoting). Optional `rest` may be omitted. Renders as `<name:rest>` /
  `[name:rest]` in help and surfaces through `available_commands`, so it is
  the GUI free-text field. Closes the r1441 quoted-parsing residual.

  *Deliberately excluded — `bool`/`enum` arg kinds.* Unlike int/real/char
  (whose tokenisation is language-neutral), a boolean has no universal
  surface syntax, so it would impose a new byte-for-byte cross-impl parity
  contract; `char` already covers the rare case; and in a modal command
  graph a boolean is better modelled as command structure (`commit` vs
  `commit-force`) than as an argument. Not a gap — a design choice.
  Enums / ranges / repeated args / custom validators stay out for the same
  "resist the kitchen-sink" reason unless a real project forces the issue.
- **Structured script results + reset API** (both impls in parity).
  `run_file` now reports outcome, not just file-open success, and stops at
  the first failing line. Fortran: optional `stat`/`errmsg`/`line` out args
  (idiomatic, like `add_command`/`finalize`) alongside the `ok` result —
  `stat = -1` for a file-open failure else the failing dispatch RC
  (`RC_UNKNOWN`/`RC_AMBIGUOUS`/`RC_ERROR`), `line` the 1-based file line.
  Tcl: returns a dict `{ok stat errmsg line}` (`stat` = `open` or the
  dispatch code word) — the same Fortran-int / Tcl-word asymmetry as
  `available_commands`. `quit` mid-script is clean (not an error). New
  public `reset`: rewinds the stack to the initial state, drops contexts,
  clears `last_message`/`last_error`; graph untouched (still finalized /
  immutable). Fortran `reset` reports misuse on an unfinalized engine via
  `stat`/`errmsg` (no `error stop`); Tcl has no finalize phase so `reset`
  always applies.
- **Fixed-N array spec helpers** (both impls in parity). `arg_int_n(name,n)`
  and `arg_real_n(name,n)` (Fortran) and `cmdgraph::arg_int_n`/`arg_real_n`
  (Tcl) return N copies of the scalar spec, composing naturally with other
  specs in an array constructor or `concat`. No engine changes — the N slots
  are ordinary positional specs validated and rendered by the existing
  machinery. Help shows each slot individually (`<pt:real> <pt:real>`).
  Variable-length arrays are deliberately excluded: fixed N covers the real
  use cases (coordinate tuples etc.) and the right approach is to compose
  existing primitives rather than extend the engine.
- **Action error message + named constructors** (both impls in parity).
  `action_result_t` gained an `errmsg` field: when an action sets it alongside
  `errored=.true.`, the engine writes it to the error channel and caches it in
  `last_error`. Tcl: the `invoke` method captures the caught error string and
  returns it in the `errmsg` key of the result dict. Named constructors
  `action_ok(?ctx?)` and `action_error(?msg?)` replace raw struct initialisation
  so action procs read unambiguously: `rv = action_error("something went wrong")`.
  `action_result_t` stays a plain data-transfer object with public fields
  (no invariants to protect), the constructors add ergonomics only.

- **C++ port** (2026-05-16; behaviour parity completed 2026-05-20). C++23,
  single header `include/cmdgraph.hxx` + `src/cmdgraph.cxx`, static library
  built by Makefile (primary: icpx, secondary: g++). Builder API, all edge
  kinds, all arg spec kinds including `ARG_REST`, introspection
  (`available_commands`, `state_path`), `run` / `run_file` / `reset`,
  `[[nodiscard]]` on `RC` and `ActionResult`, `CommandOptions` with `= {}` on
  all fields. Tokeniser uses `std::from_chars`; accepts `d`/`D` as
  Fortran-style exponent synonym for `e`/`E`. Demos: `app/main.cxx` (REPL),
  `cad_2d/cad_2d.cxx` (2D CAD). 158 unit tests, 0 failing (icpx and g++
  clean). Full behaviour parity with Tcl and Fortran is now enforced by the
  parity harness — see the cross-implementation parity entry above for the
  contract.
- **Cross-implementation parity contract + harness** (2026-05-20, all three
  implementations). A static three-language review surfaced a cluster of
  behaviour drift between the Tcl/Fortran/C++ ports — different error channels
  for `unknown`/`ambiguous`, C++ DAG validation only seeded from the initial
  state, C++ `run_file` missing comment/blank-line skipping and echo-via-info
  defaults, ambiguous-format wording variance, empty required `rest` accepted
  silently by C++, integer literal rejected in real arg slots by all three.
  A ten-phase resolution plan locked each behaviour to a single canonical
  contract (mostly the Tcl baseline) and propagated it to the other two:
  - Engine error channel: `unknown:`/`ambiguous:` route via `emit_info_` so they
    update `last_message`, not `last_error`. `last_error` is for action and
    parser errors only. `run_file` open-failure → `ok==false && line==0` is the
    documented discriminator across all three.
  - Ambiguous wording: `ambiguous: <cmd> matches a, b` (comma-space join),
    byte-identical across impls.
  - DAG validation: DFS from every concrete state as a root, not just the
    initial state — cycles in unreachable components are still caught. Cycle
    message: `cmdgraph: cycle detected: A -> B -> ... -> A` (path-trace via
    parent[] DFS), byte-identical across impls.
  - Construction-time validation: action / `do_pop` without `proc`, `goto` /
    `do_goto` without `target`, and `do_goto` without `proc`, all rejected at
    `add_command` with byte-identical wording
    `cmdgraph: <kind> edge '<spec>' missing required <proc|target>`.
  - `do_goto` truthiness: non-empty result transitions, empty stays. `"0"` /
    `"no"` / `"false"` are valid context values, not "stay" signals. Tcl
    previously used `string is boolean -strict` and was the outlier; now
    aligned.
  - Empty required `rest`: rejected as `missing required argument <name>`
    across all three (was silently accepted as `""` in C++).
  - Int→real promotion: an integer literal in a `real` arg slot is accepted
    and promoted. Tcl passes the raw token (dynamic types); C++ pushes a
    `double` variant; Fortran replaces the `dlist_node_integer` with
    `real_node(real(ival,8))` in a post-validate pass (because `validate_args`
    is `intent(in)`).

  All of the above is enforced by a cross-language parity harness at
  `tools/parity/`. Runners in Tcl, Fortran and C++ build a byte-identical
  canonical graph (see `tools/parity/GRAPH.md`), each consumes the same
  `scripts/*.in` and writes a normalised trailer (`ok rc line state
  last_message last_error`). The driver `tools/parity/run.tcl` diffs each
  channel against `tools/parity/golden/` and cross-checks impls against each
  other. Ten golden cases cover basic actions, comment/blank skip, unknown,
  ambiguous, `do_goto`-zero, `do_goto` stay/go, int→real, required-rest
  empty, numeric first token, and open-failure. Run with `make -C
  tools/parity && tclsh tools/parity/run.tcl` (defaults to gfortran + g++;
  `F=ifx CXX=icpx` for the primary toolchain). The original ROADMAP item
  "structured script results … both impls in parity" pre-dated the C++ port
  and is now fully reconciled across all three.
- **Versioning** (2026-05-16, all three implementations). Each implementation
  exposes a version type with four accessors — `major`, `minor`, `patch`,
  `string` — and a library-level constant `CMDGRAPH_VERSION`. Version is a
  library constant, not a built-in REPL command; wire it as a graph command if
  needed. `major` and `minor` are synchronised across all implementations;
  `patch` may vary. Tcl module gained `package provide cmdgraph 1.0.0`.
  Access syntax:
  - C++:     `CMDGRAPH_VERSION.major` / `.minor` / `.patch` / `.string()`
  - Fortran: `CMDGRAPH_VERSION%major` / `%minor` / `%patch` / `%string()`
  - Tcl:     `set v [cmdgraph::version]` → dict keys `major minor patch string`
- **1.1.0 release** (2026-05-21, all three implementations). Minor bump driven
  by the Tcl `do_goto` truthiness change from the parity contract above: under
  pre-parity 1.0.0 Tcl, returning `"0"` / `"no"` / `"false"` from a `do_goto`
  proc meant "stay" (via `string is boolean -strict`); under the contract,
  only the empty string means stay and those values transition with the
  string as the new state's context. Fortran and C++ were already on the
  non-empty/empty semantics, so their externally-visible behaviour is
  unchanged — but the cross-impl sync rule (`major`/`minor` synchronised) pulls
  them along to 1.1.0 as well. Fortran's intervening 1.0.0 → 1.0.1 (r1482:
  atomic finalize / empty-graph guard / dlist insert) was pure bug-fix and is
  subsumed. The Tcl module file was renamed `cmdgraph-1.0.tm` →
  `cmdgraph-1.1.tm` so Tcl's module-path version discovery matches the
  `package provide` directive. No other API or behaviour changes; all unit
  tests and the parity harness remain green on both primary (`ifx`/`icpx`)
  and secondary (`gfortran`/`g++`) toolchains.
- **1.2.0 release (Tcl only) — `cmdgraph::Shell` façade** (2026-05-21).
  A Python `cmd.Cmd`-style subclassable convenience layer on top of the
  existing Tcl engine. The subclass writes `do_<spec>` instance methods,
  the base class introspects them at construction time via
  `info object methods` and synthesises a single-state graph whose action
  edges are bound back to the instance with list-formed callbacks. Optional
  `help_<spec>` / `args_<spec>` companion methods supply per-command
  metadata. Lifecycle hooks `preloop`, `postloop`, `precmd line`, and
  `postcmd rc line` are honoured iff the subclass defines them. A real
  `quit`-kind edge labelled `q(uit)` is auto-injected unless the subclass
  already declares one. Instance helpers: `my exit` terminates the loop
  from inside an action; `my puts ?-nonewline? str` routes through the
  redirectable `out_chan` so `set_io_channels` covers user output too;
  `my engine` exposes the underlying engine for `state_path`,
  `available_commands`, etc.

  Engine change required to enable the façade: `invoke` and
  `fire_on_enter` now `{*}`-expand the registered proc slot, so a
  list-formed callback `[list $obj method_name]` works alongside the
  bare-proc-name form. Backward compatible — a bare name is a
  single-element list, so all pre-existing graphs continue to work
  unmodified. Tests: 238/238 engine (`utest_cmdgraph.tcl`) + 16/16
  façade (`utest_shell.tcl`).

  **Deliberately Tcl-only.** TclOO's runtime method introspection is what
  makes the `cmd.Cmd` shape feel native; in C++ and Fortran the equivalent
  would require explicit per-command registration and pull only marginal
  value through. The README's "Design boundary" section records the
  decision and sketches how an OO façade could be added to C++ (lambdas
  capturing `this` over the existing `std::function` action signature, no
  engine change) or Fortran (an opaque payload slot on the command record
  with explicit-`self` action signatures, mirroring Python's own `self`
  convention, ~50 lines of engine delta) if demand emerges — tracked as a
  deferred item below.

  Consequence for the version-sync rule: the original 1.0.0 versioning
  entry above stated that `major` and `minor` are synchronised across all
  implementations. This is hereby **narrowed to engine semantics**.
  Language-specific convenience layers (Shell now, others in future) live
  above the parity contract and may carry their own version trajectory.
  C++ and Fortran therefore remain at 1.1.0 (Fortran's patch lineage at
  1.0.1); the Tcl distribution moves to 1.2.0 alone. The Tcl module file
  is renamed `cmdgraph-1.1.tm` → `cmdgraph-1.2.tm` so module-path version
  discovery matches the `package provide` directive.
- **1.3.0 release — `swap` / `do_swap` edges** (2026-07-04, all three
  implementations). A new edge-kind pair that **replaces the top stack frame**
  (pop-then-push) instead of pushing: `swap <target>` mirrors `goto` but
  replace-not-push; `do_swap <target> <proc>` mirrors `do_goto` (proc error →
  stay with error; empty return → stay; non-empty return → replace the top
  frame with the target and that value as the new context). Motivated by the
  first real driver to need it — 2d_cad's tool switching, where selecting a new
  tool must **replace** the current modal tool state rather than stack another
  one, and where tools switch to each other freely (an inherently cyclic
  relationship). Because a swap is pop-then-push it does not deepen the stack
  and is inherently cyclic, so — like `pop` / `do_pop` — swap edges are
  **exempt from the `goto` / `do_goto` acyclicity check** at `finalize`; only
  their target's existence and concreteness are validated. This is an engine-
  semantics addition and thus lands across the parity contract: Fortran and C++
  bump 1.1.0 → **1.3.0** and Tcl 1.2.1 → **1.3.0**, keeping the shared engine
  `major`/`minor` synchronised (the trio skips the Tcl-only 1.2 line so the
  same minor never denotes two different engines). The Tcl module file is
  renamed `cmdgraph-1.2.1.tm` → `cmdgraph-1.3.0.tm`. The parity graph gains a
  `toola`/`toolb` mutual-swap pair (cases `11_swap`, `12_do_swap`) that pins the
  DAG exemption and the replace-not-push semantics across all three impls; the
  `.cgl` codegen learns the two new keywords. Guiding principle preserved:
  cmdgraph provides the language structure for its applications, so a missing
  language element is added to the engine (cohesively, under the parity
  contract) rather than worked around in the driver.

## Bigger — defer until a real workflow demands it

1. **State lifecycle hooks beyond `on_enter`** (`on_exit`, `before_command`,
   `after_command`, transition veto). Legitimate for real workflows, but
   larger surface; add when a concrete use case requires it rather than
   speculatively.
2. **Case-insensitive matching option.** Trivial, opt-in, low urgency.
3. **Default-value arg kind.** Let an optional arg declare a default the
   engine fills when omitted, so the action always receives a complete
   list. Consistent with the existing arg-spec intent (actions trust the
   list) rather than new scope — but low urgency: defer until a real
   action is duplicating default-fill logic, not before.
4. ~~**Update demos to use arg specs.**~~ **Done 2026-05-20.** The library
   demos (`app/main.f90`, `app/main.cxx`) were already on arg specs. The
   cad_2d demos used a dual-arity `point` command (`x y` vs `from id dx
   dy`) that could not be specced as one command; both were migrated by
   splitting into two peer commands `point <x:real> <y:real>` and `from
   <id:int> <dx:real> <dy:real>`, each with a single-arity spec validated
   by the engine. Help auto-renders the specs; actions are pure typed
   accessors.
5. **OO `Shell` façade for C++ and Fortran** (equivalent of the Tcl 1.2.0
   `cmdgraph::Shell`). The Tcl Shell is deliberately Tcl-only — see the
   1.2.0 entry above for the rationale. If a real workflow asks for the
   same subclass-and-write-methods pattern in C++ or Fortran, the
   implementation paths are sketched in the README's "Design boundary"
   section: C++ via lambdas capturing `this` over the existing
   `std::function` action signature (no engine change required); Fortran
   via an opaque payload slot on the command record alongside
   explicit-`self` action signatures, mirroring Python's own `self`
   convention (~50 lines of engine delta plus the new `shell_t` derived
   type). Neither path requires reopening the cross-impl engine parity
   contract. Defer until demand emerges — re-evaluate when a concrete app
   would benefit from it, not before.

## Known limitations — not worth fixing

- **Fixed 4096-char line buffer** in Fortran `run` and `run_file`. Lines
  longer than 4096 characters are silently truncated. In practice this is
  unreachable: interactive commands are short, and `rest`-kind free-text
  arguments are the only plausible path to long lines. Fixing it would
  require reading in chunks or the Fortran 2023 `get_line` intrinsic.
  Not scheduled; document as a limitation if needed.

## Scope tension — decide before doing

These items reverse decisions already made. They are not "todo"; they are
"choose whether to change the design."

- **Command aliases / hidden commands.** First-class aliases were deferred in
  favour of prefix matching. A real alias list is a reversal of that
  decision, not a gap.
- **Opt-in `allow_cycles`.** DAG validation of `goto` / `do_goto` edges
  (r1427) is a deliberate design invariant, not an oversight. Allowing
  cycles — even opt-in — is a design-philosophy change and should be treated
  as one.

## Explicitly out of scope

Interactive prefix/tab completion, line editing, and command history. These
belong in the GUI or a readline-style wrapper, not the dispatch engine. This
was reaffirmed when the introspection API shipped (r1446): enumeration is in
scope, resolving partial/ambiguous input is not — `find_matches` stays
private.
