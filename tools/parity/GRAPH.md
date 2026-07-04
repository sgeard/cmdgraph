# Canonical parity graph

Built identically by `runner.tcl`, `runner.f90`, `runner.cxx`.

```
initial: root

state root            prompt "root> "
  e(cho)   action   act_echo   args {text rest}      help "echo text"
  ad(d)    action   act_add    args {x int}{y int}   help "add two ints"
  s(ave)   action   act_save                         help "save"
  s(end)   action   act_send                         help "send"
  sc(ale)  action   act_scale  args {f real}         help "scale"
  o(pen)   do_goto  detail act_open  args {id int}   help "open id"
  z(ero)   do_goto  detail act_zero                  help "zero-ctx do_goto"
  g(o)     goto     detail                           help "go"
  t(ool)   goto     toola                            help "tool mode"
  q(uit)   quit                                      help "quit"

state detail          prompt "detail> "   on_enter enter_detail
  w(here)  action   act_where                        help "show context"
  u(pdate) do_pop   act_update args {note rest}      help "update note"
  b(ack)   pop                                       help "back"
  q(uit)   quit                                      help "quit"

state toola           prompt "toola> "   on_enter enter_toola
  n(ext)   swap     toolb                            help "swap to toolb"
  w(here)  action   act_where                        help "show context"
  b(ack)   pop                                       help "back"
  q(uit)   quit                                      help "quit"

state toolb           prompt "toolb> "   on_enter enter_toolb
  p(rev)   do_swap  toola act_prev args {id int}     help "swap to toola"
  w(here)  action   act_where                        help "show context"
  b(ack)   pop                                       help "back"
  q(uit)   quit                                      help "quit"
```

`toola`/`toolb` form a mutual `swap`/`do_swap` pair — inherently cyclic yet a
valid finalize, pinning the DAG exemption for swap edges across all three
impls. `swap`/`do_swap` replace the top frame (pop-then-push), so after
`t`(ool)→`n`(ext) a single `b`(ack) returns to `root`, not `toola` — the
proof that swap replaces rather than pushes.

`s(ave)`/`s(end)` share required prefix `s` -> typing `s` is **ambiguous**
(`sa`->save, `se`->send). `sc(ale)` has required prefix `sc`.

## Parity action procs — exact stdout (byte-identical across impls)

| proc         | prints                                  | returns / effect                                  |
|--------------|-----------------------------------------|---------------------------------------------------|
| act_echo     | `echo: <text>\n`                        | ok (stay)                                         |
| act_add      | `sum: <x+y>\n`                          | ok                                                |
| act_save     | `save: ok\n`                            | ok                                                |
| act_send     | `send: ok\n`                            | ok                                                |
| act_scale    | `scale: ok\n`                           | ok (value not printed — avoids float-format drift)|
| act_open     | (nothing)                               | id<=0 -> `""` (stay); else -> `<id>` (go)         |
| act_zero     | (nothing)                               | returns literal `"0"` (the do_goto-trap pin)      |
| act_where    | `where: ctx=<ctx>\n`                    | ok                                                |
| act_update   | `update: <note>\n`                      | ok -> do_pop pops                                 |
| act_prev     | (nothing)                               | id<=0 -> `""` (stay); else -> `<id>` (swap)       |
| enter_detail | `entered detail ctx=<ctx>\n`            | on_enter side effect                              |
| enter_toola  | `entered toola ctx=<ctx>\n`             | on_enter side effect                              |
| enter_toolb  | `entered toolb ctx=<ctx>\n`             | on_enter side effect                              |

Under the P0 do_goto rule a non-empty return transitions; `act_zero`
returning `"0"` therefore **transitions** (old Tcl `string is boolean
-strict` treated `"0"` as stay — the regression this pins).
