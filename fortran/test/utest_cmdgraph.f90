! Smoke test for cmdgraph_f. Mirrors a few of the key Tcl tests:
! construction, dispatch return codes, goto/do_goto/pop/quit semantics.
program utest_cmdgraph
    use cmdgraph
    use dlist
    implicit none

    integer :: pass = 0, fail = 0
    integer, save :: last_act_outer_called = 0
    integer, save :: last_select_id = -1
    integer, save :: last_commit_called = 0
    real(8), save :: last_real_arg = 0.0d0
    character(len=:), save, allocatable :: last_word_arg
    character(len=:), save, allocatable :: enter_detail_saw_ctx
    integer, save :: last_rest_nargs = -1
    integer, save :: last_rest_int = -1
    character(len=:), save, allocatable :: last_rest_str
    character(len=:), save, allocatable :: last_errmsg

    type(engine_t) :: eng

    ! --- Build a small graph: home with select/quit, detail with back ---
    call eng%add_state("home",   prompt="> ")
    call eng%add_command("home", "a(ction)", EDGE_ACTION, proc=act_outer,  help="bump counter")
    call eng%add_command("home", "s(elect)", EDGE_DO_GOTO, target="detail", proc=act_select, help="Select <id>")
    call eng%add_command("home", "g(o)",     EDGE_GOTO,   target="detail", help="Goto detail")
    call eng%add_command("home", "f(ail)",   EDGE_DO_GOTO, target="detail", proc=act_fail,    help="always fails")
    call eng%add_command("home", "r(eal)",   EDGE_ACTION, proc=act_real,     help="capture real")
    call eng%add_command("home", "w(ord)",   EDGE_ACTION, proc=act_word,     help="capture word")
    call eng%add_command("home", "s(ave)",   EDGE_ACTION, proc=act_outer,   help="save")
    call eng%add_command("home", "s(ub)",    EDGE_ACTION, proc=act_outer,   help="sub")
    call eng%add_command("home", "q(uit)",   EDGE_QUIT,   help="exit")

    call eng%add_state("detail", prompt="detail> ")
    call eng%set_on_enter("detail", enter_detail)
    call eng%add_command("detail", "b(ack)",   EDGE_POP,    help="back")
    call eng%add_command("detail", "c(ommit)", EDGE_DO_POP, proc=act_commit, help="commit + pop")
    call eng%add_command("detail", "bad",      EDGE_DO_POP, proc=act_bad_commit, help="errors, no pop")

    call eng%finalize("home")

    call check_str("starts in home",        eng%current_state(), "home")
    call check_log("is running at start",   eng%is_running(),    .true.)

    ! action edge: increments counter, returns RC_OK
    call check_int("action returns RC_OK",  eng%dispatch("action"), RC_OK)
    call check_int("action counter bumped", last_act_outer_called, 1)
    call check_str("action stayed in home", eng%current_state(), "home")

    ! prefix matching
    call check_int("'a' prefix returns RC_OK", eng%dispatch("a"), RC_OK)
    call check_int("counter bumped again",     last_act_outer_called, 2)

    ! ambiguous prefix: s matches s(elect), s(ave), s(ub)
    call check_int("'s' is ambiguous",        eng%dispatch("s"),    RC_AMBIGUOUS)
    call check_int("'sa' disambiguates save", eng%dispatch("sa"),   RC_OK)
    call check_int("full 'save' works",       eng%dispatch("save"), RC_OK)

    ! unknown command
    call check_int("unknown returns RC_UNKNOWN", eng%dispatch("nosuchcmd"), RC_UNKNOWN)

    ! built-in help and typed argument parsing
    call check_int("built-in help returns RC_OK", eng%dispatch("help"), RC_OK)
    call check_int("built-in ? returns RC_OK", eng%dispatch("?"), RC_OK)
    call check_int("real arg action returns RC_OK", eng%dispatch("real -1.25d2"), RC_OK)
    call check_log("real arg parsed", last_real_arg == -125.0d0, .true.)
    call check_int("char arg action returns RC_OK", eng%dispatch("word /tmp/path"), RC_OK)
    call check_str("char arg parsed", last_word_arg, "/tmp/path")
    call check_int("quoted char arg returns RC_OK", eng%dispatch('word "two words"'), RC_OK)
    call check_str("quoted char arg parsed", last_word_arg, "two words")
    call check_int("quoted empty arg returns RC_OK", eng%dispatch('word ""'), RC_OK)
    call check_str("quoted empty arg parsed", last_word_arg, "")
    last_word_arg = "unchanged"
    call check_int("unmatched quote returns RC_ERROR", eng%dispatch('word "two words'), RC_ERROR)
    call check_str("unmatched quote does not dispatch", last_word_arg, "unchanged")

    ! do_goto with int arg → transitions, on_enter sees context "42"
    call check_int("select transitions", eng%dispatch("select 42"), RC_TRANSITIONED)
    call check_str("now in detail",      eng%current_state(),   "detail")
    call check_str("context is 42",      eng%current_context(), "42")
    call check_str("on_enter saw ctx",   enter_detail_saw_ctx,  "42")
    call check_int("select_id captured", last_select_id,        42)

    ! pop back
    call check_int("back transitions",   eng%dispatch("back"), RC_TRANSITIONED)
    call check_str("now in home",        eng%current_state(),  "home")
    call check_str("context restored",   eng%current_context(),"")

    ! do_goto that returns no value → stays
    call check_int("fail stays",         eng%dispatch("fail"), RC_OK)
    call check_str("still in home",      eng%current_state(),  "home")

    ! goto pushes with empty context
    call check_int("go transitions",     eng%dispatch("go"), RC_TRANSITIONED)
    call check_str("now in detail",      eng%current_state(), "detail")
    call check_str("empty context",      eng%current_context(), "")
    call check_int("back again",         eng%dispatch("back"), RC_TRANSITIONED)

    ! do_pop: enter detail, then commit-and-return with a do_pop action
    call check_int("re-enter detail", eng%dispatch("select 7"), RC_TRANSITIONED)
    call check_str("in detail",       eng%current_state(),      "detail")
    call check_int("commit pops",     eng%dispatch("commit"),   RC_TRANSITIONED)
    call check_str("popped to home",  eng%current_state(),      "home")
    call check_int("commit ran",      last_commit_called,       1)

    ! do_pop with errored action: stays in detail, returns RC_ERROR
    call check_int("re-enter detail again", eng%dispatch("select 8"), RC_TRANSITIONED)
    call check_int("bad_commit errored",    eng%dispatch("bad"),      RC_ERROR)
    call check_str("still in detail",       eng%current_state(),      "detail")
    call check_int("back to home",          eng%dispatch("back"),     RC_TRANSITIONED)

    ! quit exits
    call check_int("quit exits",         eng%dispatch("quit"), RC_EXITED)
    call check_log("no longer running",  eng%is_running(),     .false.)
    call check_int("dispatch on dead",   eng%dispatch("a"),    RC_EXITED)

    call test_includes()
    call test_run_file()
    call test_reset()
    call test_io_diagnostics()
    call test_builder_errors()
    call test_introspection()
    call test_help_usage()
    call test_quiet_unit()
    call test_rest_of_line()
    call test_array_specs()
    call test_action_errmsg()
    call test_constructors()
    call test_builder_errors2()
    call test_finalize_errors()
    call test_multi_include()
    call test_dispatch_special()
    call test_run_engine()
    call test_run_file_rc_error()
    call test_rest_lead_exhaustion()
    call test_pop_at_root()
    call test_do_pop_errmsg_set()
    call test_do_pop_at_root()
    call test_stack_resize()
    call test_help_no_help_text()
    call test_run_with_prompt()
    call test_include_override()
    call test_validate_args_char()

    ! --- version ---
    call check_int("version major",  CMDGRAPH_VERSION%major, 1)
    call check_int("version minor",  CMDGRAPH_VERSION%minor, 0)
    call check_int("version patch",  CMDGRAPH_VERSION%patch, 0)
    call check_str("version string", CMDGRAPH_VERSION%string(), "1.0.0")

    ! --- Done ---
    write(*,'(/,a,i0,a,i0,a,i0,a)') "Results: ", pass+fail, " tests, ", pass, " passed, ", fail, " failed"
    if (fail > 0) error stop 1

contains

    function act_outer(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        last_act_outer_called = last_act_outer_called + 1
    end function act_outer

    function act_select(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        character(len=16)                     :: buf

        if (args%size() /= 1) then
            rv%errored = .true.
            return
        end if
        n = args%get(1)
        select type (n)
        type is (dlist_node_integer)
            last_select_id = n%data
            write(buf, '(i0)') n%data
            rv%value = trim(buf)
        class default
            rv%errored = .true.
        end select
    end function act_select

    function act_fail(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        ! Leaves rv%value unallocated — no transition.
    end function act_fail

    function act_real(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        if (args%size() /= 1) then
            rv%errored = .true.
            return
        end if
        n = args%get(1)
        select type (n)
        type is (dlist_node_real)
            last_real_arg = n%data
        class default
            rv%errored = .true.
        end select
    end function act_real

    function act_word(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        if (args%size() /= 1) then
            rv%errored = .true.
            return
        end if
        n = args%get(1)
        select type (n)
        type is (dlist_node_char)
            last_word_arg = n%data
        class default
            rv%errored = .true.
        end select
    end function act_word

    function act_rest(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        last_rest_nargs = args%size()
        last_rest_int   = -1
        if (allocated(last_rest_str)) deallocate(last_rest_str)
        if (last_rest_nargs >= 1) then
            n = args%get(1)
            select type (n)
            type is (dlist_node_integer)
                last_rest_int = n%data
            end select
            n = args%get(last_rest_nargs)
            select type (n)
            type is (dlist_node_char)
                last_rest_str = n%data
            end select
        end if
    end function act_rest

    function act_commit(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        last_commit_called = last_commit_called + 1
    end function act_commit

    function act_bad_commit(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        rv%errored = .true.
    end function act_bad_commit

    subroutine enter_detail(ctx)
        character(len=*), intent(in)          :: ctx
        enter_detail_saw_ctx = ctx
    end subroutine enter_detail

    subroutine test_includes()
        type(engine_t) :: e
        call e%add_state("common")
        call e%add_command("common", "x(shared)", EDGE_ACTION, proc=act_outer, help="shared")
        call e%add_state("root", prompt="root> ")
        call e%add_include("root", "common")
        call e%add_command("root", "q(uit)", EDGE_QUIT, help="exit")
        call e%finalize("root")

        last_act_outer_called = 0
        call check_int("included command dispatches", e%dispatch("xshared"), RC_OK)
        call check_int("included command ran action", last_act_outer_called, 1)
        call test_includes_are_flat()
    end subroutine test_includes

    ! Codex Medium #1: b includes a; a includes common. b must NOT inherit
    ! common's commands (Tcl semantics: includes are flat, resolved from the
    ! parsed graph, not from already-merged states). Also verify the result
    ! is independent of state declaration order.
    subroutine test_includes_are_flat()
        type(engine_t) :: e1, e2

        ! Order 1: common-first.
        call e1%add_state("common")
        call e1%add_command("common", "c(ommon)", EDGE_ACTION, proc=act_outer)
        call e1%add_state("a", prompt="a> ")
        call e1%add_include("a", "common")
        call e1%add_command("a", "a(ction)", EDGE_ACTION, proc=act_outer)
        call e1%add_state("b", prompt="b> ")
        call e1%add_include("b", "a")
        call e1%add_command("b", "b(ction)", EDGE_ACTION, proc=act_outer)
        call e1%add_command("b", "q(uit)", EDGE_QUIT)
        call e1%finalize("b")

        call check_int("common-first: b sees a's command",   e1%dispatch("action"), RC_OK)
        call check_int("common-first: b sees its own",        e1%dispatch("bction"), RC_OK)
        call check_int("common-first: b does NOT see common", e1%dispatch("common"), RC_UNKNOWN)

        ! Order 2: b declared first (states out of dependency order). The fix
        ! must make the result identical to order 1.
        call e2%add_state("b", prompt="b> ")
        call e2%add_state("a", prompt="a> ")
        call e2%add_state("common")
        call e2%add_include("b", "a")
        call e2%add_include("a", "common")
        call e2%add_command("common", "c(ommon)", EDGE_ACTION, proc=act_outer)
        call e2%add_command("a", "a(ction)", EDGE_ACTION, proc=act_outer)
        call e2%add_command("b", "b(ction)", EDGE_ACTION, proc=act_outer)
        call e2%add_command("b", "q(uit)", EDGE_QUIT)
        call e2%finalize("b")

        call check_int("b-first: b sees a's command",   e2%dispatch("action"), RC_OK)
        call check_int("b-first: b sees its own",        e2%dispatch("bction"), RC_OK)
        call check_int("b-first: b does NOT see common", e2%dispatch("common"), RC_UNKNOWN)
    end subroutine test_includes_are_flat

    subroutine test_run_file()
        type(engine_t) :: e, e2
        character(len=*), parameter :: script_path = "/tmp/cmdgraph_fortran_utest.txt"
        character(len=*), parameter :: bad_path = "/tmp/cmdgraph_fortran_bad_utest.txt"
        integer :: u, s, ln
        logical :: ok
        character(len=:), allocatable :: m

        call e%add_state("root", prompt="> ")
        call e%add_command("root", "a(ction)", EDGE_ACTION, proc=act_outer, help="run")
        call e%add_command("root", "q(uit)", EDGE_QUIT, help="exit")
        call e%finalize("root")

        ok = e%run_file("/tmp/cmdgraph_fortran_missing.txt")
        call check_log("run_file missing returns false", ok, .false.)
        call check_str("run_file missing keeps state", e%current_state(), "root")

        open(newunit=u, file=script_path, status="replace", action="write")
        write(u,'(a)') "# comment"
        write(u,'(a)') ""
        write(u,'(a)') "action"
        write(u,'(a)') "quit"
        write(u,'(a)') "action"
        close(u)

        last_act_outer_called = 0
        ok = e%run_file(script_path)
        call check_log("run_file existing returns true", ok, .true.)
        call check_log("run_file stops at quit", e%is_running(), .false.)
        call check_int("run_file ran only before quit", last_act_outer_called, 1)

        open(newunit=u, file=script_path, status="old")
        close(u, status="delete")

        ! Structured file-open failure: ok=.false., stat=-1, line=0.
        ok = e%run_file("/tmp/cmdgraph_fortran_missing.txt", &
                         stat=s, errmsg=m, line=ln)
        call check_log("run_file missing ok false", ok, .false.)
        call check_int("run_file missing stat -1", s, -1)
        call check_int("run_file missing line 0", ln, 0)
        call check_log("run_file missing errmsg set", &
            index(m, "could not open") > 0, .true.)

        ! Stop-on-first-error: structured stat/errmsg/line, later lines skipped.
        call e2%add_state("root", prompt="> ")
        call e2%add_command("root", "a(ction)", EDGE_ACTION, proc=act_outer)
        call e2%add_command("root", "q(uit)", EDGE_QUIT)
        call e2%finalize("root")
        call e2%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)

        open(newunit=u, file=bad_path, status="replace", action="write")
        write(u,'(a)') "# header"
        write(u,'(a)') "action"
        write(u,'(a)') "badcmd here"
        write(u,'(a)') "action"
        close(u)

        last_act_outer_called = 0
        ok = e2%run_file(bad_path, echo=.false., stat=s, errmsg=m, line=ln)
        call check_log("run_file bad ok false", ok, .false.)
        call check_int("run_file bad stat unknown", s, RC_UNKNOWN)
        call check_int("run_file bad line number", ln, 3)
        call check_str("run_file bad errmsg", m, "unknown: badcmd")
        call check_int("run_file stopped before line 4", last_act_outer_called, 1)

        open(newunit=u, file=bad_path, status="old")
        close(u, status="delete")
    end subroutine test_run_file

    subroutine test_reset()
        type(engine_t) :: e, fresh
        integer :: s, rc
        character(len=:), allocatable :: m

        ! reset on an unfinalized engine -> stat error, no crash.
        call fresh%reset(stat=s, errmsg=m)
        call check_int("reset unfinalized stat", s, 1)
        call check_log("reset unfinalized errmsg", &
            index(m, "not finalized") > 0, .true.)

        call e%add_state("home", prompt="> ")
        call e%add_state("detail", prompt="d> ")
        call e%add_command("home", "s(elect)", EDGE_DO_GOTO, target="detail", &
                           proc=act_select, args=[arg_is_int("id")])
        call e%add_command("home", "q(uit)", EDGE_QUIT)
        call e%add_command("detail", "b(ack)", EDGE_POP)
        call e%finalize("home")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)

        rc = e%dispatch('select "x')
        call check_int("reset: error path hit", rc, RC_ERROR)
        call check_log("reset: last_error set", len(e%last_error) > 0, .true.)
        rc = e%dispatch("select 42")
        call check_str("reset: pushed before", e%current_state(), "detail")

        call e%reset(stat=s)
        call check_int("reset: stat ok", s, 0)
        call check_str("reset: back at initial", e%current_state(), "home")
        call check_int("reset: stack depth 1", size(e%state_path()), 1)
        call check_str("reset: last_error cleared", e%last_error, "")
        call check_log("reset: still running", e%is_running(), .true.)

        rc = e%dispatch("quit")
        call check_log("reset: exited", e%is_running(), .false.)
        call e%reset()
        call check_log("reset: revived after quit", e%is_running(), .true.)
        call check_str("reset: home after quit-reset", e%current_state(), "home")
    end subroutine test_reset

    subroutine test_io_diagnostics()
        type(engine_t) :: e
        character(len=*), parameter :: script_path = "/tmp/cmdgraph_fortran_io_utest.txt"
        integer :: u
        logical :: ok

        call e%add_state("root", prompt="> ")
        call e%add_command("root", "a(ction)", EDGE_ACTION, proc=act_outer, help="run")
        call e%add_command("root", "q(uit)", EDGE_QUIT, help="exit")
        call e%finalize("root")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)

        call check_int("unknown still returns RC_UNKNOWN when quiet", &
                       e%dispatch("nosuch"), RC_UNKNOWN)
        call check_str("unknown recorded as last_message", &
                       e%last_message, "unknown: nosuch")

        call check_int("parse error still returns RC_ERROR when quiet", &
                       e%dispatch('action "unterminated'), RC_ERROR)
        call check_str("parse error recorded as last_error", &
                       e%last_error, "unmatched quote in arguments")

        e%last_message = "sentinel"
        open(newunit=u, file=script_path, status="replace", action="write")
        write(u,'(a)') "action"
        write(u,'(a)') "quit"
        close(u)

        last_act_outer_called = 0
        ok = e%run_file(script_path, echo=.false.)
        call check_log("run_file echo false returns true", ok, .true.)
        call check_int("run_file echo false still dispatches", last_act_outer_called, 1)
        call check_str("run_file echo false does not update last_message", &
                       e%last_message, "sentinel")

        open(newunit=u, file=script_path, status="old")
        close(u, status="delete")
    end subroutine test_io_diagnostics

    ! Exercise the optional-stat/errmsg error path on every builder method.
    ! No `error stop` should fire; failures come back via stat/errmsg and the
    ! engine carries a sticky build_error that finalize re-surfaces.
    subroutine test_builder_errors()
        type(engine_t)                :: e
        integer                       :: s
        character(len=:), allocatable :: m

        ! Duplicate state name -> stat=1, message returned, no crash.
        call e%add_state("home")
        call e%add_state("home", stat=s, errmsg=m)
        call check_int("dup state returns nonzero stat", s, 1)
        call check_log("dup state allocates errmsg", allocated(m), .true.)
        call check_int("dup state poisons engine", e%build_error_stat, 1)

        ! Subsequent builder calls are no-ops that propagate the stuck error.
        call e%add_command("home", "a(ction)", EDGE_ACTION, proc=act_outer, stat=s, errmsg=m)
        call check_int("propagated stat on poisoned engine", s, 1)

        ! Finalize re-surfaces the build error.
        call e%finalize("home", stat=s, errmsg=m)
        call check_int("finalize surfaces build error", s, 1)
        call check_log("finalize errmsg matches first error", &
                       index(m, "already added") > 0, .true.)

        ! Mutation after a successful finalize on a fresh engine: blocked.
        block
            type(engine_t) :: e2
            integer        :: s2
            character(len=:), allocatable :: m2
            call e2%add_state("root", prompt="r> ")
            call e2%add_command("root", "q(uit)", EDGE_QUIT)
            call e2%finalize("root")
            call e2%add_command("root", "x(tra)", EDGE_QUIT, stat=s2, errmsg=m2)
            call check_int("post-finalize mutation rejected via stat", s2, 1)
            call check_log("post-finalize errmsg mentions finalized", &
                           index(m2, "already finalized") > 0, .true.)
        end block

        ! Unknown state in add_command -> stat=1, no crash.
        block
            type(engine_t) :: e3
            integer        :: s3
            character(len=:), allocatable :: m3
            call e3%add_state("only")
            call e3%add_command("missing", "a", EDGE_QUIT, stat=s3, errmsg=m3)
            call check_int("unknown state in add_command -> stat", s3, 1)
            call check_log("unknown state errmsg mentions state name", &
                           index(m3, "'missing'") > 0, .true.)
        end block

        ! Missing required attr (action without proc) -> stat=1, no crash.
        block
            type(engine_t) :: e4
            integer        :: s4
            character(len=:), allocatable :: m4
            call e4%add_state("s")
            call e4%add_command("s", "a(ct)", EDGE_ACTION, stat=s4, errmsg=m4)
            call check_int("action without proc -> stat", s4, 1)
            call check_log("missing-proc errmsg mentions 'proc'", &
                           index(m4, "missing required proc") > 0, .true.)
        end block
    end subroutine test_builder_errors

    subroutine check_str(label, got, expected)
        character(len=*), intent(in) :: label, got, expected
        if (got == expected) then
            write(*,'(a)') "PASS: " // label
            pass = pass + 1
        else
            write(*,'(a)') "FAIL: " // label // " (got '" // got // "', expected '" // expected // "')"
            fail = fail + 1
        end if
    end subroutine check_str

    subroutine check_int(label, got, expected)
        character(len=*), intent(in) :: label
        integer, intent(in)          :: got, expected
        character(len=16)            :: bg, be
        if (got == expected) then
            write(*,'(a)') "PASS: " // label
            pass = pass + 1
        else
            write(bg,'(i0)') got
            write(be,'(i0)') expected
            write(*,'(a)') "FAIL: " // label // " (got " // trim(bg) // ", expected " // trim(be) // ")"
            fail = fail + 1
        end if
    end subroutine check_int

    subroutine check_log(label, got, expected)
        character(len=*), intent(in) :: label
        logical, intent(in)          :: got, expected
        if (got .eqv. expected) then
            write(*,'(a)') "PASS: " // label
            pass = pass + 1
        else
            write(*,'(a)') "FAIL: " // label
            fail = fail + 1
        end if
    end subroutine check_log

    subroutine test_introspection()
        type(engine_t)                    :: e
        type(command_info_t), allocatable :: cmds(:), cmds2(:)
        character(len=:), allocatable     :: path(:)
        integer                           :: i, sidx
        logical                           :: same

        call e%add_state("home", prompt="> ")
        call e%add_state("detail", prompt="d> ")
        call e%add_command("home", "s(elect)", EDGE_DO_GOTO, target="detail", &
                           proc=act_select, args=[arg_is_int("id")], help="Select <id>")
        call e%add_command("home", "q(uit)", EDGE_QUIT, help="exit")
        call e%add_command("detail", "b(ack)", EDGE_POP, help="back")
        call e%finalize("home")

        cmds = e%available_commands()
        call check_int("available_commands count in home", size(cmds), 2)

        cmds2 = e%available_commands()
        same = (size(cmds2) == size(cmds))
        if (same) then
            do i = 1, size(cmds)
                if (cmds2(i)%spec /= cmds(i)%spec) same = .false.
            end do
        end if
        call check_log("available_commands deterministic", same, .true.)

        sidx = 0
        do i = 1, size(cmds)
            if (cmds(i)%spec == "s(elect)") sidx = i
        end do
        call check_log("command_info found s(elect)", sidx /= 0, .true.)
        call check_str("command_info req",    cmds(sidx)%req,    "s")
        call check_str("command_info opt",    cmds(sidx)%opt,    "elect")
        call check_int("command_info kind",   cmds(sidx)%kind,   EDGE_DO_GOTO)
        call check_str("command_info target", cmds(sidx)%target, "detail")
        call check_str("command_info help",   cmds(sidx)%help,   "Select <id>")
        call check_log("command_info args allocated", allocated(cmds(sidx)%args), .true.)
        call check_int("command_info args size", size(cmds(sidx)%args), 1)
        call check_int("command_info arg kind",  cmds(sidx)%args(1)%kind, ARG_INT)

        path = e%state_path()
        call check_int("state_path size at root", size(path), 1)
        call check_str("state_path root name",    trim(path(1)), "home")

        call check_int("select transitions", e%dispatch("select 5"), RC_TRANSITIONED)
        path = e%state_path()
        call check_int("state_path size in detail", size(path), 2)
        call check_str("state_path[2] is detail",   trim(path(2)), "detail")
        cmds = e%available_commands()
        call check_int("available_commands in detail", size(cmds), 1)
        call check_int("detail command is pop", cmds(1)%kind, EDGE_POP)

        call check_int("back transitions", e%dispatch("back"), RC_TRANSITIONED)
        path = e%state_path()
        call check_int("state_path size after pop", size(path), 1)

        call check_int("quit exits", e%dispatch("quit"), RC_EXITED)
        cmds = e%available_commands()
        call check_int("available_commands empty when stopped", size(cmds), 0)
        path = e%state_path()
        call check_int("state_path empty when stopped", size(path), 0)
    end subroutine test_introspection

    subroutine test_help_usage()
        type(engine_t) :: e
        character(len=*), parameter :: hp = "/tmp/cmdgraph_fortran_help_utest.txt"
        integer                       :: u, ios, p
        character(len=512)            :: line
        character(len=:), allocatable :: txt, ql
        logical                       :: has_q_adorn

        call e%add_state("home", prompt="> ")
        call e%add_command("home", "s(elect)", EDGE_ACTION, proc=act_outer, &
                           args=[arg_is_int("id")], help="Select <id>")
        call e%add_command("home", "r(eal)", EDGE_ACTION, proc=act_outer, &
                           args=[arg_is_real("x")], help="Capture real")
        call e%add_command("home", "w(ord)", EDGE_ACTION, proc=act_outer, &
                           args=[arg_is_char("name")], help="Capture word")
        call e%add_command("home", "p(air)", EDGE_ACTION, proc=act_outer, &
                           args=[arg_is_int("id"), arg_is_char("label", optional=.true.)], &
                           help="Optional label")
        call e%add_command("home", "q(uit)", EDGE_QUIT, help="exit")
        call e%finalize("home")

        open(newunit=u, file=hp, status="replace", action="write")
        call e%set_io_units(output_unit=u)
        call check_int("help usage dispatch ok", e%dispatch("help"), RC_OK)
        close(u)

        txt = ""
        open(newunit=u, file=hp, status="old", action="read")
        do
            read(u,'(a)', iostat=ios) line
            if (ios /= 0) exit
            txt = txt // trim(line) // new_line('a')
        end do
        close(u, status="delete")

        call check_log("usage: required int arg", &
            index(txt, "s(elect) <id:int>") > 0, .true.)
        call check_log("usage: required real arg", &
            index(txt, "r(eal) <x:real>") > 0, .true.)
        call check_log("usage: required char arg", &
            index(txt, "w(ord) <name:char>") > 0, .true.)
        call check_log("usage: required + optional", &
            index(txt, "p(air) <id:int> [label:char]") > 0, .true.)
        call check_log("usage: help text preserved", &
            index(txt, "Select <id>") > 0, .true.)

        ! q(uit) takes no args and its help text ("exit") has no brackets,
        ! so the whole q(uit) line must contain neither '<' nor '['.
        p  = index(txt, "q(uit)")
        ql = txt(p:)
        p  = index(ql, new_line('a'))
        if (p > 0) ql = ql(1:p-1)
        has_q_adorn = (index(ql, "<") > 0) .or. (index(ql, "[") > 0)
        call check_log("usage: no-arg command plain", has_q_adorn, .false.)
    end subroutine test_help_usage

    ! Regression: a negative open(newunit=) file unit must receive engine
    ! output (the > 0 guard wrongly suppressed it); QUIET_UNIT must still
    ! suppress even when a real unit was previously configured.
    subroutine test_quiet_unit()
        type(engine_t) :: e
        character(len=*), parameter :: cp = "/tmp/cmdgraph_fortran_quiet_utest.txt"
        integer            :: u, ios, nlines
        character(len=256) :: line

        call e%add_state("home", prompt="> ")
        call e%add_command("home", "a(ction)", EDGE_ACTION, proc=act_outer, help="run")
        call e%add_command("home", "q(uit)", EDGE_QUIT, help="exit")
        call e%finalize("home")

        ! newunit -> negative unit; must NOT be treated as quiet.
        open(newunit=u, file=cp, status="replace", action="write")
        call check_log("newunit file unit is negative", u < 0, .true.)
        call e%set_io_units(output_unit=u)
        call check_int("help to newunit unit ok", e%dispatch("help"), RC_OK)
        close(u)

        nlines = 0
        open(newunit=u, file=cp, status="old", action="read")
        do
            read(u,'(a)', iostat=ios) line
            if (ios /= 0) exit
            nlines = nlines + 1
        end do
        close(u, status="delete")
        call check_log("newunit unit received output", nlines > 0, .true.)

        ! QUIET_UNIT overrides a previously real unit -> nothing written.
        open(newunit=u, file=cp, status="replace", action="write")
        call e%set_io_units(output_unit=u)
        call e%set_io_units(output_unit=QUIET_UNIT)
        call check_int("help while quiet ok", e%dispatch("help"), RC_OK)
        close(u)

        nlines = 0
        open(newunit=u, file=cp, status="old", action="read")
        do
            read(u,'(a)', iostat=ios) line
            if (ios /= 0) exit
            nlines = nlines + 1
        end do
        close(u, status="delete")
        call check_int("QUIET_UNIT suppresses output", nlines, 0)
    end subroutine test_quiet_unit

    subroutine test_rest_of_line()
        type(engine_t) :: e, bad
        character(len=*), parameter :: hp = "/tmp/cmdgraph_fortran_rest_utest.txt"
        integer                       :: u, ios, p, s
        character(len=512)            :: line
        character(len=:), allocatable :: txt
        character(len=:), allocatable :: m

        call e%add_state("home", prompt="> ")
        call e%add_command("home", "e(cho)", EDGE_ACTION, proc=act_rest, &
                           args=[arg_is_rest("text")], help="Echo rest")
        call e%add_command("home", "n(ote)", EDGE_ACTION, proc=act_rest, &
                           args=[arg_is_int("id"), arg_is_rest("body")], &
                           help="Note id + body")
        call e%add_command("home", "o(pt)", EDGE_ACTION, proc=act_rest, &
                           args=[arg_is_int("id"), arg_is_rest("body", optional=.true.)], &
                           help="Optional rest")
        call e%add_command("home", "t(ag)", EDGE_ACTION, proc=act_rest, &
                           args=[arg_is_char("label"), arg_is_rest("body")], &
                           help="Tag + body")
        call e%add_command("home", "q(uit)", EDGE_QUIT, help="exit")
        call e%finalize("home")

        call check_int("rest: verbatim multiword", &
            e%dispatch("echo hello big world"), RC_OK)
        call check_str("rest: captured verbatim", last_rest_str, "hello big world")
        call check_int("rest: single arg", last_rest_nargs, 1)

        call check_int("rest: leading run stripped", &
            e%dispatch("echo   a  b "), RC_OK)
        call check_str("rest: internal preserved", last_rest_str, "a  b")
        call check_int("rest: trailing preserved (len)", len(last_rest_str), 5)

        call check_int("rest: leading int then rest", &
            e%dispatch("note 5 buy milk and eggs"), RC_OK)
        call check_int("rest: lead int parsed", last_rest_int, 5)
        call check_str("rest: body verbatim", last_rest_str, "buy milk and eggs")
        call check_int("rest: two args", last_rest_nargs, 2)

        last_rest_nargs = -1
        if (allocated(last_rest_str)) deallocate(last_rest_str)
        call check_int("rest: optional omitted ok", e%dispatch("opt 9"), RC_OK)
        call check_int("rest: optional omitted arity", last_rest_nargs, 1)
        call check_int("rest: optional omitted id", last_rest_int, 9)
        call check_log("rest: optional omitted no str", &
            allocated(last_rest_str), .false.)

        call check_int("rest: optional present ok", &
            e%dispatch("opt 9 hello there"), RC_OK)
        call check_int("rest: optional present arity", last_rest_nargs, 2)
        call check_str("rest: optional present body", last_rest_str, "hello there")

        call check_int("rest: embedded quotes kept", &
            e%dispatch('echo he said "hi"'), RC_OK)
        call check_str("rest: quotes not stripped", last_rest_str, 'he said "hi"')

        call check_int("rest: lone quote allowed", &
            e%dispatch('echo a " b'), RC_OK)
        call check_str("rest: lone quote verbatim", last_rest_str, 'a " b')

        call check_int("rest: missing required body", &
            e%dispatch("note 5"), RC_ERROR)

        call check_int("rest: lead quote still checked", &
            e%dispatch('tag "unterminated body'), RC_ERROR)

        ! rest must be the last spec slot -> construction error via stat.
        call bad%add_state("home", prompt="> ")
        call bad%add_command("home", "x", EDGE_ACTION, proc=act_rest, &
            args=[arg_is_rest("body"), arg_is_int("id")], stat=s, errmsg=m)
        call check_int("rest must be last rejected", s, 1)
        call check_log("rest-not-last errmsg", &
            index(m, "rest arg must be the last") > 0, .true.)

        ! Help renders <name:rest> and [name:rest].
        open(newunit=u, file=hp, status="replace", action="write")
        call e%set_io_units(output_unit=u)
        call check_int("rest: help dispatch ok", e%dispatch("help"), RC_OK)
        close(u)
        txt = ""
        open(newunit=u, file=hp, status="old", action="read")
        do
            read(u,'(a)', iostat=ios) line
            if (ios /= 0) exit
            txt = txt // trim(line) // new_line('a')
        end do
        close(u, status="delete")
        call check_log("rest: help renders required", &
            index(txt, "e(cho) <text:rest>") > 0, .true.)
        call check_log("rest: help renders optional", &
            index(txt, "o(pt) <id:int> [body:rest]") > 0, .true.)
    end subroutine test_rest_of_line

    subroutine test_array_specs()
        type(engine_t)                :: e
        type(arg_spec_t), allocatable :: specs(:)
        character(len=*), parameter   :: hp = "/tmp/cmdgraph_fortran_array_utest.txt"
        integer                       :: u, ios
        character(len=512)            :: line
        character(len=:), allocatable :: txt

        ! --- Constructor checks ---
        specs = arg_int_n("x", 3)
        call check_int("arg_int_n: count",    size(specs),    3)
        call check_int("arg_int_n: kind[1]",  specs(1)%kind,  ARG_INT)
        call check_int("arg_int_n: kind[3]",  specs(3)%kind,  ARG_INT)
        call check_str("arg_int_n: name",     specs(1)%name,  "x")

        specs = arg_real_n("pt", 2)
        call check_int("arg_real_n: count",   size(specs),    2)
        call check_int("arg_real_n: kind[1]", specs(1)%kind,  ARG_REAL)
        call check_int("arg_real_n: kind[2]", specs(2)%kind,  ARG_REAL)
        call check_str("arg_real_n: name",    specs(1)%name,  "pt")

        ! --- Array constructors mix with scalar specs in an array constructor ---
        specs = [arg_is_char("label"), arg_real_n("pt", 2)]
        call check_int("mixed: count",        size(specs),    3)
        call check_int("mixed: [1] char",     specs(1)%kind,  ARG_CHAR)
        call check_int("mixed: [2] real",     specs(2)%kind,  ARG_REAL)
        call check_int("mixed: [3] real",     specs(3)%kind,  ARG_REAL)

        ! --- Dispatch validation ---
        call e%add_state("home", prompt="> ")
        call e%add_command("home", "p(oint)", EDGE_ACTION, proc=act_outer, &
                           args=arg_real_n("pt", 2), help="Enter 2D point")
        call e%add_command("home", "i(nt3)", EDGE_ACTION, proc=act_outer, &
                           args=arg_int_n("n", 3), help="Three ints")
        call e%finalize("home")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)

        call check_int("real[2]: exact count ok",    e%dispatch("p 1.0 2.0"),     RC_OK)
        call check_int("real[2]: too few",           e%dispatch("p 1.0"),          RC_ERROR)
        call check_int("real[2]: too many",          e%dispatch("p 1.0 2.0 3.0"),  RC_ERROR)
        call check_int("real[2]: wrong type",        e%dispatch("p 1.0 foo"),      RC_ERROR)
        call check_int("int[3]: exact count ok",     e%dispatch("i 1 2 3"),        RC_OK)
        call check_int("int[3]: too few",            e%dispatch("i 1 2"),           RC_ERROR)
        call check_int("int[3]: wrong type",         e%dispatch("i 1 2 3.5"),      RC_ERROR)

        ! --- Help renders each slot ---
        open(newunit=u, file=hp, status="replace", action="write")
        call e%set_io_units(output_unit=u)
        call check_int("array help dispatch ok", e%dispatch("help"), RC_OK)
        close(u)
        txt = ""
        open(newunit=u, file=hp, status="old", action="read")
        do
            read(u,'(a)', iostat=ios) line
            if (ios /= 0) exit
            txt = txt // trim(line) // new_line('a')
        end do
        close(u, status="delete")
        call check_log("array help: 2 real slots", &
            index(txt, "p(oint) <pt:real> <pt:real>") > 0, .true.)
        call check_log("array help: 3 int slots", &
            index(txt, "i(nt3) <n:int> <n:int> <n:int>") > 0, .true.)
    end subroutine test_array_specs

    subroutine test_action_errmsg()
        type(engine_t) :: e

        call e%add_state("home", prompt="> ")
        call e%add_state("dest", prompt="dest> ")
        call e%add_command("home", "f(ail)", EDGE_ACTION,   proc=act_fail_msg,    help="fails with message")
        call e%add_command("home", "s(ilent)", EDGE_ACTION, proc=act_fail_silent, help="fails without message")
        call e%add_command("home", "d(o)", EDGE_DO_GOTO, target="dest", &
                           proc=act_do_fail_msg, help="do_goto fails with message")
        call e%add_command("dest", "b(ack)", EDGE_POP, help="back")
        call e%finalize("home")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)

        ! EDGE_ACTION: errmsg propagates to last_error
        call check_int("errmsg: action RC_ERROR",    e%dispatch("fail"),   RC_ERROR)
        call check_str("errmsg: action last_error",  e%last_error,         "something went wrong")

        ! EDGE_ACTION: no errmsg leaves last_error unchanged
        call e%reset()
        call check_int("errmsg: silent RC_ERROR",    e%dispatch("silent"), RC_ERROR)
        call check_str("errmsg: silent last_error",  e%last_error,         "")

        ! EDGE_DO_GOTO: errmsg propagates
        call check_int("errmsg: do_goto RC_ERROR",   e%dispatch("do"),     RC_ERROR)
        call check_str("errmsg: do_goto last_error", e%last_error,         "do_goto failed")
    end subroutine test_action_errmsg

    function act_fail_msg(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        rv = action_error("something went wrong")
    end function act_fail_msg

    function act_fail_silent(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        rv = action_error()
    end function act_fail_silent

    function act_do_fail_msg(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        rv = action_error("do_goto failed")
    end function act_do_fail_msg

    subroutine test_constructors()
        type(action_result_t) :: rv

        ! action_ok with no ctx: errored=.false., value unallocated
        rv = action_ok()
        call check_log("action_ok() errored=F",     .not. rv%errored,                    .true.)
        call check_log("action_ok() value unalloc", .not. allocated(rv%value),           .true.)

        ! action_ok with ctx: value is set
        rv = action_ok("my-ctx")
        call check_log("action_ok(ctx) errored=F",  .not. rv%errored,                    .true.)
        call check_str("action_ok(ctx) value",      rv%value,                            "my-ctx")

        ! action_error with no msg: errored=.true., errmsg unallocated
        rv = action_error()
        call check_log("action_error() errored=T",  rv%errored,                          .true.)
        call check_log("action_error() msg unalloc",.not. allocated(rv%errmsg),          .true.)

        ! action_error with msg: errmsg is set
        rv = action_error("oops")
        call check_log("action_error(msg) errored=T", rv%errored,                        .true.)
        call check_str("action_error(msg) errmsg",    rv%errmsg,                         "oops")
    end subroutine test_constructors

    ! action_ok with an allocated-but-empty value → do_goto stays in current state
    function act_empty_ctx(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        rv%value = ""
    end function act_empty_ctx

    ! ── Coverage completers ───────────────────────────────────────────────────

    subroutine test_builder_errors2()
        ! add_state after finalize
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_command("root", "q(uit)", EDGE_QUIT)
            call e%finalize("root")
            call e%add_state("extra", stat=s, errmsg=m)
            call check_int("add_state after finalize stat", s, 1)
            call check_log("add_state after finalize errmsg", &
                index(m, "already finalized") > 0, .true.)
        end block

        ! add_command EDGE_GOTO missing target
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_command("root", "g", EDGE_GOTO, stat=s, errmsg=m)
            call check_int("EDGE_GOTO missing target stat", s, 1)
            call check_log("EDGE_GOTO missing target errmsg", &
                index(m, "missing required") > 0, .true.)
        end block

        ! add_command EDGE_DO_GOTO missing target (has proc, no target)
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_command("root", "g", EDGE_DO_GOTO, proc=act_outer, stat=s, errmsg=m)
            call check_int("EDGE_DO_GOTO missing target stat", s, 1)
            call check_log("EDGE_DO_GOTO missing target errmsg", &
                index(m, "missing required") > 0, .true.)
        end block

        ! add_command EDGE_DO_GOTO missing proc (has target, no proc)
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_state("dest", prompt="dest> ")
            call e%add_command("root", "g", EDGE_DO_GOTO, target="dest", stat=s, errmsg=m)
            call check_int("EDGE_DO_GOTO missing proc stat", s, 1)
            call check_log("EDGE_DO_GOTO missing proc errmsg", &
                index(m, "missing required") > 0, .true.)
        end block

        ! add_command EDGE_DO_POP missing proc
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_command("root", "c", EDGE_DO_POP, stat=s, errmsg=m)
            call check_int("EDGE_DO_POP missing proc stat", s, 1)
            call check_log("EDGE_DO_POP missing proc errmsg", &
                index(m, "missing required") > 0, .true.)
        end block

        ! add_command unknown edge kind
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_command("root", "x", 999, stat=s, errmsg=m)
            call check_int("unknown edge kind stat", s, 1)
            call check_log("unknown edge kind errmsg", &
                index(m, "unknown edge kind") > 0, .true.)
        end block

        ! add_include: find_state_idx on engine with no states yet (covers line 624)
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_include("nosuch", "x", stat=s, errmsg=m)
            call check_int("add_include empty engine stat", s, 1)
        end block

        ! add_include after finalize
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_command("root", "q(uit)", EDGE_QUIT)
            call e%finalize("root")
            call e%add_include("root", "extra", stat=s, errmsg=m)
            call check_int("add_include after finalize stat", s, 1)
            call check_log("add_include after finalize errmsg", &
                index(m, "already finalized") > 0, .true.)
        end block

        ! add_include unknown source state
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_include("nosuch", "root", stat=s, errmsg=m)
            call check_int("add_include unknown state stat", s, 1)
            call check_log("add_include unknown state errmsg", &
                index(m, "'nosuch'") > 0, .true.)
        end block

        ! set_on_enter after finalize
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_command("root", "q(uit)", EDGE_QUIT)
            call e%finalize("root")
            call e%set_on_enter("root", enter_detail, stat=s, errmsg=m)
            call check_int("set_on_enter after finalize stat", s, 1)
            call check_log("set_on_enter after finalize errmsg", &
                index(m, "already finalized") > 0, .true.)
        end block

        ! set_on_enter unknown state
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%set_on_enter("nosuch", enter_detail, stat=s, errmsg=m)
            call check_int("set_on_enter unknown state stat", s, 1)
            call check_log("set_on_enter unknown state errmsg", &
                index(m, "'nosuch'") > 0, .true.)
        end block

        ! finalize on already finalized engine
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_command("root", "q(uit)", EDGE_QUIT)
            call e%finalize("root")
            call e%finalize("root", stat=s, errmsg=m)
            call check_int("finalize already finalized stat", s, 1)
            call check_log("finalize already finalized errmsg", &
                index(m, "already finalized") > 0, .true.)
        end block

    end subroutine test_builder_errors2

    subroutine test_finalize_errors()
        ! Abstract state with no commands → allocate(original(i)%items(0)) path
        block
            type(engine_t) :: e
            integer :: s
            call e%add_state("common")             ! abstract, no commands added
            call e%add_state("root", prompt="> ")
            call e%add_include("root", "common")
            call e%add_command("root", "q(uit)", EDGE_QUIT)
            call e%finalize("root", stat=s)
            call check_int("finalize: abstract no-cmd state ok", s, 0)
        end block

        ! Include pointing to nonexistent state → finalize catches it
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_include("root", "phantom")  ! stored verbatim at add-time
            call e%add_command("root", "q(uit)", EDGE_QUIT)
            call e%finalize("root", stat=s, errmsg=m)
            call check_int("finalize: unknown include state stat", s, 1)
            call check_log("finalize: unknown include state errmsg", &
                index(m, "phantom") > 0, .true.)
        end block

        ! GOTO targeting nonexistent state → finalize catches it
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_command("root", "g", EDGE_GOTO, target="phantom")
            call e%add_command("root", "q(uit)", EDGE_QUIT)
            call e%finalize("root", stat=s, errmsg=m)
            call check_int("finalize: GOTO unknown target stat", s, 1)
            call check_log("finalize: GOTO unknown target errmsg", &
                index(m, "phantom") > 0, .true.)
        end block

        ! GOTO targeting abstract state → finalize catches it
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("abst")               ! no prompt → abstract
            call e%add_state("root", prompt="> ")
            call e%add_command("root", "g", EDGE_GOTO, target="abst")
            call e%add_command("root", "q(uit)", EDGE_QUIT)
            call e%finalize("root", stat=s, errmsg=m)
            call check_int("finalize: GOTO abstract target stat", s, 1)
            call check_log("finalize: GOTO abstract target errmsg", &
                index(m, "abst") > 0, .true.)
        end block

        ! Nonexistent initial state
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("root", prompt="> ")
            call e%add_command("root", "q(uit)", EDGE_QUIT)
            call e%finalize("phantom", stat=s, errmsg=m)
            call check_int("finalize: unknown initial stat", s, 1)
            call check_log("finalize: unknown initial errmsg", &
                index(m, "phantom") > 0, .true.)
        end block

        ! Abstract initial state
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%add_state("abst")               ! no prompt → abstract
            call e%finalize("abst", stat=s, errmsg=m)
            call check_int("finalize: abstract initial stat", s, 1)
            call check_log("finalize: abstract initial errmsg", &
                index(m, "abst") > 0, .true.)
        end block

    end subroutine test_finalize_errors

    subroutine test_multi_include()
        ! Adding two includes to the same state exercises the array-resize path
        ! in add_include_engine (lines 176-184 in cmdgraph_sm.f90).
        type(engine_t) :: e

        call e%add_state("cmn1")
        call e%add_command("cmn1", "x(shared)", EDGE_ACTION, proc=act_outer)
        call e%add_state("cmn2")
        call e%add_command("cmn2", "y(shared)", EDGE_ACTION, proc=act_outer)
        call e%add_state("root", prompt="> ")
        call e%add_include("root", "cmn1")   ! first include — creates array
        call e%add_include("root", "cmn2")   ! second include — resizes array
        call e%add_command("root", "q(uit)", EDGE_QUIT)
        call e%finalize("root")

        last_act_outer_called = 0
        call check_int("multi-include: first cmd ok",  e%dispatch("xshared"), RC_OK)
        call check_int("multi-include: second cmd ok", e%dispatch("yshared"), RC_OK)
        call check_int("multi-include: both ran",      last_act_outer_called, 2)
    end subroutine test_multi_include

    subroutine test_dispatch_special()
        type(engine_t) :: e1, e2

        ! 1. Blank and single-space dispatch → RC_OK, no transition
        call e1%add_state("home", prompt="> ")
        call e1%add_command("home", "q(uit)", EDGE_QUIT)
        call e1%finalize("home")
        call e1%set_io_units(output_unit=QUIET_UNIT)

        call check_int("dispatch blank → RC_OK",  e1%dispatch(""),  RC_OK)
        call check_int("dispatch space → RC_OK",  e1%dispatch(" "), RC_OK)
        call check_str("state unchanged after blank", e1%current_state(), "home")

        ! current_state/current_context on stopped engine (stack_top = 0 after quit)
        call check_int("dispatch quit exits", e1%dispatch("quit"), RC_EXITED)
        call check_str("current_state dead → empty",   e1%current_state(),   "")
        call check_str("current_context dead → empty", e1%current_context(), "")

        ! 2. EDGE_DO_GOTO returning empty value → stays, returns RC_OK (line 937)
        call e2%add_state("home", prompt="> ")
        call e2%add_state("dest", prompt="dest> ")
        call e2%add_command("home", "g(o)", EDGE_DO_GOTO, target="dest", proc=act_empty_ctx)
        call e2%add_command("home", "q(uit)", EDGE_QUIT)
        call e2%add_command("dest", "b(ack)", EDGE_POP)
        call e2%finalize("home")
        call e2%set_io_units(output_unit=QUIET_UNIT)

        call check_int("do_goto empty ctx → RC_OK",   e2%dispatch("go"), RC_OK)
        call check_str("do_goto empty ctx stays home", e2%current_state(), "home")

    end subroutine test_dispatch_special

    subroutine test_run_engine()
        type(engine_t) :: e
        character(len=*), parameter :: script_path = "/tmp/cmdgraph_fortran_run_engine_utest.txt"
        integer :: u

        call e%add_state("root", prompt="> ")
        call e%add_command("root", "a(ction)", EDGE_ACTION, proc=act_outer, help="run")
        call e%add_command("root", "q(uit)",   EDGE_QUIT,   help="exit")
        call e%finalize("root")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)

        open(newunit=u, file=script_path, status="replace", action="write")
        write(u,'(a)') "action"
        write(u,'(a)') "action"
        write(u,'(a)') "quit"
        close(u)

        last_act_outer_called = 0
        open(newunit=u, file=script_path, status="old", action="read")
        call e%set_io_units(input_unit=u)
        call e%run()
        close(u)

        call check_int("run: dispatched both actions", last_act_outer_called, 2)
        call check_log("run: stopped after quit",      e%is_running(), .false.)

        open(newunit=u, file=script_path, status="old")
        close(u, status="delete")
    end subroutine test_run_engine

    subroutine test_run_file_rc_error()
        type(engine_t) :: e
        character(len=*), parameter :: script_path = "/tmp/cmdgraph_fortran_rcerr_utest.txt"
        integer :: u, s, ln
        logical :: ok
        character(len=:), allocatable :: m

        call e%add_state("root", prompt="> ")
        call e%add_command("root", "s(elect)", EDGE_ACTION, proc=act_outer, &
                           args=[arg_is_int("id")])
        call e%add_command("root", "q(uit)", EDGE_QUIT)
        call e%finalize("root")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)

        open(newunit=u, file=script_path, status="replace", action="write")
        write(u,'(a)') "select 42"
        write(u,'(a)') "select foo"   ! wrong arg type → RC_ERROR
        write(u,'(a)') "quit"
        close(u)

        ok = e%run_file(script_path, echo=.false., stat=s, errmsg=m, line=ln)
        call check_log("run_file RC_ERROR returns false", ok, .false.)
        call check_int("run_file RC_ERROR stat",         s,  RC_ERROR)
        call check_int("run_file RC_ERROR line",         ln, 2)
        call check_log("run_file RC_ERROR errmsg set",   len(m) > 0, .true.)

        open(newunit=u, file=script_path, status="old")
        close(u, status="delete")
    end subroutine test_run_file_rc_error

    subroutine test_rest_lead_exhaustion()
        ! A command with two required leading ints plus a rest arg, dispatched
        ! with only one int, exercises the parse_args_lead early-exit path
        ! (lines 773-774 in cmdgraph_sm.f90).
        type(engine_t) :: e

        call e%add_state("home", prompt="> ")
        call e%add_command("home", "n(ote)", EDGE_ACTION, proc=act_rest, &
                           args=[arg_is_int("x"), arg_is_int("y"), arg_is_rest("body")])
        call e%finalize("home")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)

        call check_int("lead exhaustion → RC_ERROR", e%dispatch("note 5"), RC_ERROR)
    end subroutine test_rest_lead_exhaustion

    function act_bad_msg(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        rv%errored = .true.
        rv%errmsg  = "explicit error message"
    end function act_bad_msg

    subroutine test_pop_at_root()
        ! EDGE_POP at depth 1 (root) exhausts the stack → RC_EXITED
        type(engine_t) :: e
        call e%add_state("root", prompt="> ")
        call e%add_command("root", "b(ack)", EDGE_POP)
        call e%finalize("root")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)
        call check_int("pop at root → RC_EXITED", e%dispatch("back"), RC_EXITED)
        call check_log("engine stopped after pop at root", e%is_running(), .false.)
    end subroutine test_pop_at_root

    subroutine test_do_pop_errmsg_set()
        ! DO_POP action returning action_error with a non-empty message exercises
        ! the emit_error branch inside apply_edge.
        type(engine_t) :: e
        call e%add_state("root",   prompt="> ")
        call e%add_state("detail", prompt="d> ")
        call e%add_command("root",   "g(o)",     EDGE_GOTO,   target="detail")
        call e%add_command("detail", "c(ommit)", EDGE_DO_POP, proc=act_bad_msg)
        call e%finalize("root")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)
        call check_int("enter detail",             e%dispatch("go"),     RC_TRANSITIONED)
        call check_int("do_pop with errmsg → RC_ERROR", e%dispatch("commit"), RC_ERROR)
        call check_log("last_error set",           len(e%last_error) > 0, .true.)
    end subroutine test_do_pop_errmsg_set

    subroutine test_do_pop_at_root()
        ! DO_POP succeeds at depth 1 → stack empties → RC_EXITED
        type(engine_t) :: e
        call e%add_state("root", prompt="> ")
        call e%add_command("root", "c(ommit)", EDGE_DO_POP, proc=act_commit)
        call e%finalize("root")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)
        call check_int("do_pop at root → RC_EXITED", e%dispatch("commit"), RC_EXITED)
        call check_log("engine stopped", e%is_running(), .false.)
    end subroutine test_do_pop_at_root

    subroutine test_stack_resize()
        ! Push 8 states deep to exceed the initial stack capacity of 8,
        ! triggering the push_stack array-resize path.
        type(engine_t) :: e
        call e%add_state("root", prompt="> ")
        call e%add_command("root", "g", EDGE_GOTO, target="s1")
        call e%add_state("s1", prompt="1> ")
        call e%add_command("s1", "g", EDGE_GOTO, target="s2")
        call e%add_state("s2", prompt="2> ")
        call e%add_command("s2", "g", EDGE_GOTO, target="s3")
        call e%add_state("s3", prompt="3> ")
        call e%add_command("s3", "g", EDGE_GOTO, target="s4")
        call e%add_state("s4", prompt="4> ")
        call e%add_command("s4", "g", EDGE_GOTO, target="s5")
        call e%add_state("s5", prompt="5> ")
        call e%add_command("s5", "g", EDGE_GOTO, target="s6")
        call e%add_state("s6", prompt="6> ")
        call e%add_command("s6", "g", EDGE_GOTO, target="s7")
        call e%add_state("s7", prompt="7> ")
        call e%add_command("s7", "g", EDGE_GOTO, target="s8")
        call e%add_state("s8", prompt="8> ")
        call e%add_command("s8", "q", EDGE_QUIT)
        call e%finalize("root")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)
        call check_int("depth 2", e%dispatch("g"), RC_TRANSITIONED)
        call check_int("depth 3", e%dispatch("g"), RC_TRANSITIONED)
        call check_int("depth 4", e%dispatch("g"), RC_TRANSITIONED)
        call check_int("depth 5", e%dispatch("g"), RC_TRANSITIONED)
        call check_int("depth 6", e%dispatch("g"), RC_TRANSITIONED)
        call check_int("depth 7", e%dispatch("g"), RC_TRANSITIONED)
        call check_int("depth 8", e%dispatch("g"), RC_TRANSITIONED)
        call check_int("depth 9 (resize)", e%dispatch("g"), RC_TRANSITIONED)
        call check_str("at s8 after resize", e%current_state(), "s8")
    end subroutine test_stack_resize

    subroutine test_help_no_help_text()
        ! A command with no help text exercises the else branch in show_help.
        type(engine_t) :: e
        integer :: u
        call e%add_state("root", prompt="> ")
        call e%add_command("root", "q(uit)", EDGE_QUIT)
        call e%finalize("root")
        open(newunit=u, file="/tmp/cmdgraph_help_notext_utest.txt", &
             status="replace", action="write")
        call e%set_io_units(output_unit=u, error_unit=QUIET_UNIT)
        call check_int("help with no-help cmd → RC_OK", e%dispatch("help"), RC_OK)
        close(u, status="delete")
    end subroutine test_help_no_help_text

    subroutine test_run_with_prompt()
        ! run() with a real output_unit exercises emit_prompt's write+flush path.
        type(engine_t) :: e
        character(len=*), parameter :: script  = "/tmp/cmdgraph_run_prompt_in_utest.txt"
        character(len=*), parameter :: outfile = "/tmp/cmdgraph_run_prompt_out_utest.txt"
        integer :: in_u, out_u
        call e%add_state("root", prompt="> ")
        call e%add_command("root", "q(uit)", EDGE_QUIT, help="exit")
        call e%finalize("root")
        open(newunit=in_u, file=script, status="replace", action="write")
        write(in_u,'(a)') "quit"
        close(in_u)
        open(newunit=in_u,  file=script,  status="old",     action="read")
        open(newunit=out_u, file=outfile, status="replace",  action="write")
        call e%set_io_units(input_unit=in_u, output_unit=out_u, error_unit=QUIET_UNIT)
        call e%run()
        close(in_u)
        close(out_u)
        call check_log("run with real output: last_message set", len(e%last_message) > 0, .true.)
        open(newunit=in_u, file=script,  status="old"); close(in_u, status="delete")
        open(newunit=in_u, file=outfile, status="old"); close(in_u, status="delete")
    end subroutine test_run_with_prompt

    subroutine test_include_override()
        ! When a concrete state includes an abstract that has the same command spec,
        ! the state's own command wins via the merge_commands override path.
        type(engine_t) :: e
        call e%add_state("base")
        call e%add_command("base", "q(uit)", EDGE_ACTION, proc=act_outer, help="base quit")
        call e%add_state("root", prompt="> ")
        call e%add_command("root", "q(uit)", EDGE_QUIT, help="real quit")
        call e%add_include("root", "base")
        call e%finalize("root")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)
        last_act_outer_called = 0
        call check_int("override: own QUIT wins → RC_EXITED", e%dispatch("quit"), RC_EXITED)
        call check_int("override: act_outer not called", last_act_outer_called, 0)
    end subroutine test_include_override

    subroutine test_validate_args_char()
        ! Covers validate_args ARG_CHAR: matching char token (line 1427) and
        ! mismatched integer token (lines 1429-1431).
        type(engine_t) :: e
        call e%add_state("root", prompt="> ")
        call e%add_command("root", "w(ord)", EDGE_ACTION, proc=act_word, &
                           args=[arg_is_char("name")])
        call e%finalize("root")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)
        last_word_arg = ""
        call check_int("char arg → RC_OK",        e%dispatch("word hello"), RC_OK)
        call check_str("char arg value",           last_word_arg, "hello")
        call check_int("int token for char → RC_ERROR", e%dispatch("word 42"), RC_ERROR)
    end subroutine test_validate_args_char

end program utest_cmdgraph
