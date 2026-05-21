# Review — `tcl/cmdgraph-1.2.tm`

Fresh assessment (2026-05-21) of the Tcl reference implementation at version
1.2.0. Reads only the code, the demo (`demo_shell.tcl`), and the two test
suites (`utest_cmdgraph.tcl`: 238/238 PASS; `utest_shell.tcl`: 16/16 PASS).

---

## 1 · What it is

A **pushdown transducer** in Tcl. Two layers in one file:

- **`cmdgraph::Engine`** — kernel. Declarative state graph drives a runtime
  stack of `{state, context}` frames. Six edge kinds (`action`, `goto`,
  `do_goto`, `pop`, `do_pop`, `quit`) cover stay/push/pop/exit with optional
  side-effects. Graph is parsed → resolved (includes merged) → validated
  (target existence, abstract-vs-concrete, **DAG enforcement** with
  white/gray/black DFS) at construction; finalized and immutable thereafter.
- **`cmdgraph::Shell`** — single-state facade. Synthesises a graph from
  `do_<spec>` / `help_<spec>` / `args_<spec>` methods on a subclass, with
  `preloop`/`postloop`/`precmd`/`postcmd` lifecycle hooks. Auto-injects
  `q(uit)` when the subclass doesn't define one.

Tcl idioms that look right for the codebase:
- TclOO + `tailcall` for recursive parser helpers — flat stack.
- All output through `emit_prompt`/`emit_info`/`emit_error`; channels fully
  redirectable; `last_message`/`last_error` cached for programmatic callers.
- Action callbacks accept bare proc name *or* list-form callback (`[list $obj
  method]`), expanded with `{*}` — the mechanism `Shell` uses to bind
  commands to instance methods.

---

## 2 · Comparison to Python's `cmd.Cmd`

| Concern                       | Python `cmd`                            | `cmdgraph::Shell`                              | `cmdgraph::Engine` (no analog in `cmd`) |
|-------------------------------|-----------------------------------------|------------------------------------------------|-----------------------------------------|
| Dispatch model                | Single state, exact match               | Single state, **prefix match** (`do_g(reet)`)  | Multi-state pushdown with stack/context |
| Arg parsing                   | Caller gets one raw string              | Typed `args_<spec>`: int/real/char/rest, optional, validated | Same                      |
| `do_*` / `help_*`             | ✓                                       | ✓ + `args_<spec>`                              | n/a (declarative graph)                 |
| Lifecycle hooks               | `preloop`/`postloop`/`precmd`/`postcmd` | Identical contract                             | Engine has `on_enter` per state         |
| Quit / EOF                    | `EOF` convention                        | Auto-injected `q(uit)`, `my exit`              | `quit` edge; `pop` empties → exit       |
| Tab completion / history      | `complete_*` via readline               | **Out of scope by design**                     | Same                                    |
| `default(line)` for unknowns  | ✓ overridable                           | **Missing**                                    | Returns `"unknown"` to caller           |
| `emptyline()`                 | ✓                                       | **Missing**                                    | Dispatches empty as `"ok"` no-op        |
| `intro` banner                | `intro = "..."`                         | Override `preloop`                             | Override hook                           |
| Aliases                       | DIY                                     | DIY                                            | DIY                                     |
| Channel redirection           | `self.stdin`/`stdout`                   | `set_io_channels in out err`                   | Same                                    |
| Scripted input                | `cmdqueue` (in-band)                    | `run_file` → `{ok stat errmsg line}`           | Same                                    |
| Modes / sub-shells            | DIY (nested `cmdloop`)                  | DIY                                            | **First-class**                         |
| Programmatic introspection    | Reflection over `do_*`                  | `available_commands`, `state_path`             | Same                                    |

**Verdict.** `cmdgraph::Shell` is genuinely a Python-`cmd`-class Tcl module —
trades tab completion (real loss) for **typed arg validation, prefix
matching, and a pushdown engine underneath for free**. The real
differentiator is not `Shell` but that the same machinery scales to
multi-state modal CAD-style interfaces that `cmd` can't express without
nesting `cmdloop`s by hand. The cad_2d demo is the proof.

---

## 3 · Real-world utility

**Where it earns its keep**:

1. **Modal interactive tools** — anything where the user "selects an object"
   then "operates on it": DB row editors, portfolio shells, debugger-style
   interfaces, instrument control, drafting consoles. The `context` riding
   on the stack is the right primitive; otherwise reinvented as a global.
2. **Legacy state-graph porting** — the origin story.
3. **Quick scripted REPLs** via `cmdgraph::Shell`. Typed-arg validation
   alone removes a class of bugs.
4. **GUI back-ends** — `available_commands`, `state_path`, channel
   redirection, structured dispatch return codes make it usable as the
   *engine* behind a graphical menu/palette UI without modification. This
   was part of the original use case.

**Where it doesn't compete**:

- End-user shells expecting tab completion, history, line editing — out of
  scope by design. Pair with `rlwrap` or a GUI.
- Polyglot ecosystems without Tcl. (The Fortran/C++ parity is for the
  author's portfolio, not for adoption breadth.)
- Anything needing boolean/enum args, multi-quote handling, or rich
  completion — deliberate minimalism caps the ceiling.

---

## 4 · Bugs and latent issues

Ordered by likelihood of biting a real user.

### 4.1 Real bugs (planned fixes)

**B1 — Nested `dispatch` corrupts `cmdgraph::context`** (`cmdgraph-1.2.tm:820–829`, also `:794–806`).

Both `invoke` and `fire_on_enter` unconditionally clear
`::cmdgraph::current_context` to `""` at the end:

```tcl
set ::cmdgraph::current_context [my top_ctx]
set rc [catch {{*}$proc_name {*}$arg_list} result]
set ::cmdgraph::current_context ""        ;# clobbers any outer save
```

If an action calls `$engine dispatch` recursively (or anything that does),
the inner call resets the variable to `""` before the outer action resumes.
Outer action's later `cmdgraph::context` returns `""` instead of its real
context. Fix is save/restore:

```tcl
set saved $::cmdgraph::current_context
set ::cmdgraph::current_context [my top_ctx]
...
set ::cmdgraph::current_context $saved
```

Same change needed in `fire_on_enter`. Not exercised by the test suite. High
priority because **GUI back-ends are likely to drive `dispatch`
programmatically**, including from inside actions.

**B2 — `Shell::cmdloop` doesn't honour the `""`-means-suppressed
convention** (`cmdgraph-1.2.tm:1031`).

Engine's `emit_prompt` guards with `if {$out_chan ne ""}`. Shell's loop
bypasses `emit_prompt` and writes the prompt directly:

```tcl
puts -nonewline $out_chan $prompt_str
flush $out_chan
```

If a Shell caller does `$shell set_io_channels stdin "" stderr` (the
documented "suppress output" idiom from the Engine), `puts` raises *can not
find channel named ""*. Fix: route Shell's prompt through `$engine
emit_prompt`, or add the same `ne ""` guard.

**B3 — Auto-injected `q(uit)` collides with any other `q…` command**
(`cmdgraph-1.2.tm:964–982`).

`BuildCommands` only detects an existing quit by `$full eq "quit"`. A
subclass defining, say, `do_q(uery)` keeps `has_quit = 0`, so `q(uit)` is
injected — and typing `q` now produces `ambiguous: q matches q(uery),
q(uit)`. Author didn't ask for that. Fix options:

- Skip auto-injection whenever any other `do_q*` exists.
- Inject under a non-colliding spec (`qu(it)`).
- Detect the collision at construction and refuse with a clear error.

Preferred: **refuse with a clear error** (silent injection of a different
spec is worse than failing loudly; skipping auto-injection means the shell
has no quit at all which silently locks the user in).

### 4.2 Lesser issues / footguns (not planned now)

**B4 — Initial state's `on_enter` is never fired.** Constructor pushes the
initial frame at `:262` without `fire_on_enter`; `reset` (`:453`) likewise.
Only `goto`/`do_goto` transitions invoke the hook. Document, or fire on
construction/reset.

**B5 — Fortran-style `1d3` accepted as `real`, then handed verbatim to
actions.** `is_real_token` (`:748–750`) accepts `[eEdD]` exponents for
cross-impl parity. Tcl's `expr` rejects `d`/`D`, so the obvious action body
`expr {$x + 1}` errors at runtime when the user types `add 1d3`. Document
or provide a `cmdgraph::to_tcl_real` helper.

**B6 — `apply_edge` switch has no `default` arm** (`:752–792`). Unreachable
in practice (construction validates), but a `default { error … }` is cheap
belt-and-braces.

**B7 — `apply_edge` ignores `fire_on_enter` errors.** A failing `on_enter`
prints to stderr but `apply_edge` returns `"transitioned"`. Documented as
"purely side-effecting"; flag if real graphs ever want refusal-on-error.

**B8 — `args_<spec>` on auto-injected `q(uit)` is silently ignored.** Mild
surprise; document or honour.

**B9 — `unquote_arg_token`** (`:664–671`) strips only outermost-pair quotes.
`"foo"bar"baz"` → `foo"bar"baz`. Probably fine; add a comment.

**B10 — `HasMethod` is O(M) per call** (`:1044–1046`), invoked on every
`precmd`/`postcmd`. Trivial for typical subclasses; cache if it ever shows
up in a profile.

---

## 5 · Missing features

### 5.1 Genuine omissions (small wins, not planned now)

- **`default(line)` hook on Shell** — overridable unknown-command handler.
- **`emptyline()` hook on Shell** — matches `cmd.Cmd`.
- **`intro` text** — convention rather than override-`preloop` boilerplate.
- **Built-in `where` / `state_path` command** — useful in nested graphs;
  data is there.
- **Aliases at Shell level** — `method alias {short long}`, ~10 lines.

### 5.2 Explicitly excluded (and rightly so, per ROADMAP)

- Tab completion, history, multi-line input — `rlwrap` / GUI / readline.
- Boolean and enum arg kinds — model as command structure or use `char`.
- Variable-length arg arrays — fixed-N helpers suffice.
- `\"` escapes inside quoted tokens — `rest` covers the natural use case.

---

## 6 · Plan

Land in this order:

1. **B1** — nested-dispatch context save/restore in `invoke` and
   `fire_on_enter`. Add a regression test that drives a nested
   `dispatch` from inside an action and checks the outer context survives.
2. **B2** — Shell prompt respects `""` = suppressed. Either route through
   `emit_prompt` or add the guard. Add a test that drives a Shell with
   `out_chan = ""` and asserts no error.
3. **B3** — `BuildCommands` errors at construction when a subclass defines
   a `do_q*` other than something resolving to full-spec `quit`. Add a
   test exercising the collision.

Everything else (B4–B10, §5.1) stays for a later pass; `sqr` is the
higher-priority project. Possible follow-up: try writing a small CAD
application driven by `cmdgraph::Engine` to validate the GUI back-end
story end-to-end — but not before `sqr` is finished.
