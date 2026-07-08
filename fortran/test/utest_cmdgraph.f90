!! SPDX-License-Identifier: MIT
!! Copyright (c) 2026 Simon Geard
!!
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
    integer, save :: swap_enter_a = 0, swap_enter_b = 0
    character(len=:), save, allocatable :: swap_ctx_b
    ! on_enter-ordering probe (Phase 5): the hook records the context it was
    ! handed at fire time and a fire counter.  Stack depth is asserted via the
    ! engine after the dispatch returns (== fire-time depth for these edges).
    integer, save :: hook_fire_count = 0
    character(len=:), save, allocatable :: hook_ctx_at_fire
    character(len=:), save, allocatable :: last_node_type

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
    ! Note: this `r(eal)` command has no arg spec, so parse_args creates the
    ! list node from the literal type — there is no validation/promotion path
    ! to exercise here.  Int → real promotion (typed-real slot accepts an
    ! integer literal and normalises to real(8)) is tested in
    ! test_int_to_real_promotion below.
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
    call test_finalize_retry()
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
    call test_int_to_real_promotion()
    call test_swap()
    call test_do_swap()
    call test_swap_builder_errors()
    call test_builder_error_messages_exact()
    call test_state_capacity_growth()
    call test_abbrev_boundaries()
    call test_target_idx_transitions()
    call test_on_enter_ordering()
    call test_do_pop_error_keeps_frame()
    call test_action_error_no_msg()
    call test_tokeniser_edges()

    ! --- version ---
    call check_int("version major",  CMDGRAPH_VERSION%major, 1)
    call check_int("version minor",  CMDGRAPH_VERSION%minor, 3)
    call check_int("version patch",  CMDGRAPH_VERSION%patch, 1)
    call check_str("version string", CMDGRAPH_VERSION%string(), "1.3.1")

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
        integer                       :: u, ios, s
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

        ! Codex Medium #2: a fresh engine (states unallocated) finalized
        ! directly must report a normal construction error, not hit
        ! size() on an unallocated allocatable.
        block
            type(engine_t) :: e
            integer :: s
            character(len=:), allocatable :: m
            call e%finalize("root", stat=s, errmsg=m)
            call check_int("finalize: empty graph stat", s, 1)
            call check_log("finalize: empty graph errmsg", &
                index(m, "no states") > 0, .true.)
        end block

    end subroutine test_finalize_errors

    ! Codex Medium #1: finalize trims/parses/merges before validating the
    ! initial state. A failed finalize must leave the engine byte-identical
    ! to before the call, so a corrected retry succeeds without dropping the
    ! merged-in (included) commands. Pre-fix, the retry re-trimmed to the
    ! stale build_count and silently lost "xshared".
    subroutine test_finalize_retry()
        type(engine_t) :: e
        integer :: s
        character(len=:), allocatable :: m

        call e%add_state("common")
        call e%add_command("common", "x(shared)", EDGE_ACTION, proc=act_outer, help="shared")
        call e%add_state("root", prompt="> ")
        call e%add_include("root", "common")
        call e%add_command("root", "q(uit)", EDGE_QUIT)

        ! Fails at initial-state validation, which runs AFTER trim + merge.
        call e%finalize("phantom", stat=s, errmsg=m)
        call check_int("retry: first finalize fails",          s, 1)
        call check_log("retry: failure names bad initial",     index(m, "phantom") > 0, .true.)

        ! Corrected retry must succeed with the merged graph fully intact.
        call e%finalize("root", stat=s)
        call check_int("retry: second finalize ok",            s, 0)
        last_act_outer_called = 0
        call check_int("retry: included command survives",     e%dispatch("xshared"), RC_OK)
        call check_int("retry: included action ran",           last_act_outer_called, 1)
        call check_int("retry: own command survives",          e%dispatch("quit"), RC_EXITED)
    end subroutine test_finalize_retry

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

    subroutine build_swap_graph(e)
        ! root --go--> toola <==swap==> toolb ; the toola<->toolb swap cycle
        ! finalizes cleanly, proving swap edges are DAG-exempt.
        type(engine_t), intent(inout) :: e
        call e%add_state("root",  prompt="r> ")
        call e%add_command("root", "g(o)",   EDGE_GOTO, target="toola")
        call e%add_command("root", "q(uit)", EDGE_QUIT)
        call e%add_state("toola", prompt="a> ")
        call e%set_on_enter("toola", enter_swap_a)
        call e%add_command("toola", "n(ext)", EDGE_SWAP, target="toolb")
        call e%add_command("toola", "b(ack)", EDGE_POP)
        call e%add_state("toolb", prompt="b> ")
        call e%set_on_enter("toolb", enter_swap_b)
        call e%add_command("toolb", "p(ick)", EDGE_DO_SWAP, target="toola", proc=act_swap_pick)
        call e%add_command("toolb", "f(ail)", EDGE_DO_SWAP, target="toola", proc=act_fail_msg)
        call e%add_command("toolb", "b(ack)", EDGE_POP)
    end subroutine build_swap_graph

    subroutine test_swap()
        ! SWAP replaces the top frame (pop-then-push): after go+next, a single
        ! back lands in root, not toola — the depth did not grow.
        type(engine_t) :: e
        integer        :: s
        swap_enter_a = 0
        swap_enter_b = 0
        call build_swap_graph(e)
        call e%finalize("root", stat=s)
        call check_int("swap-cycle graph finalizes", s, 0)
        call check_str("starts in root", e%current_state(), "root")

        call check_int("go transitions", e%dispatch("go"),   RC_TRANSITIONED)
        call check_str("now in toola",   e%current_state(),  "toola")
        call check_int("on_enter toola fired", swap_enter_a, 1)

        call check_int("next swaps",      e%dispatch("next"), RC_TRANSITIONED)
        call check_str("now in toolb",    e%current_state(),  "toolb")
        call check_str("swap empties context", e%current_context(), "")
        call check_int("on_enter toolb fired", swap_enter_b, 1)

        ! Replace-not-push: one pop returns to root (would be toola if swap pushed).
        call check_int("back transitions",  e%dispatch("back"), RC_TRANSITIONED)
        call check_str("popped to root",     e%current_state(),  "root")
    end subroutine test_swap

    subroutine test_do_swap()
        ! DO_SWAP: proc error stays (RC_ERROR); empty return stays (RC_OK);
        ! non-empty return replaces the top frame with that value as context.
        type(engine_t) :: e
        swap_enter_a = 0
        swap_enter_b = 0
        if (allocated(swap_ctx_b)) deallocate(swap_ctx_b)
        call build_swap_graph(e)
        call e%finalize("root")
        call e%set_io_units(error_unit=QUIET_UNIT)

        call check_int("go to toola",   e%dispatch("go"),   RC_TRANSITIONED)
        call check_int("next to toolb",  e%dispatch("next"), RC_TRANSITIONED)

        ! error path — stays in toolb, no swap
        call check_int("do_swap error stays",  e%dispatch("fail"), RC_ERROR)
        call check_str("still in toolb",       e%current_state(),  "toolb")

        ! empty-return path — pick with id<=0 vetoes the swap
        call check_int("do_swap empty stays",  e%dispatch("pick 0"), RC_OK)
        call check_str("still in toolb again", e%current_state(),    "toolb")

        ! non-empty return — swap to toola, id as context, on_enter sees it
        swap_enter_a = 0
        call check_int("do_swap transitions",  e%dispatch("pick 7"), RC_TRANSITIONED)
        call check_str("now in toola",         e%current_state(),    "toola")
        call check_str("context is 7",         e%current_context(),  "7")
        call check_int("on_enter toola fired", swap_enter_a, 1)

        ! Replace-not-push: one back from toola returns to root.
        call check_int("back to root", e%dispatch("back"), RC_TRANSITIONED)
        call check_str("in root",      e%current_state(),  "root")
    end subroutine test_do_swap

    subroutine test_swap_builder_errors()
        ! swap needs a target; do_swap needs target + proc; bad swap target
        ! is caught at finalize.
        type(engine_t)                :: e
        integer                       :: s
        character(len=:), allocatable :: m

        block
            type(engine_t) :: e1
            call e1%add_state("s", prompt="> ")
            call e1%add_command("s", "n(ext)", EDGE_SWAP, stat=s, errmsg=m)
            call check_int("swap without target -> stat", s, 1)
            call check_log("swap errmsg mentions target", &
                           index(m, "missing required target") > 0, .true.)
        end block

        block
            type(engine_t) :: e2
            call e2%add_state("s", prompt="> ")
            call e2%add_command("s", "p(ick)", EDGE_DO_SWAP, target="s", stat=s, errmsg=m)
            call check_int("do_swap without proc -> stat", s, 1)
            call check_log("do_swap errmsg mentions proc", &
                           index(m, "missing required proc") > 0, .true.)
        end block

        ! Bad swap target surfaces at finalize, like goto.
        call e%add_state("only", prompt="> ")
        call e%add_command("only", "n(ext)", EDGE_SWAP, target="ghost")
        call e%finalize("only", stat=s, errmsg=m)
        call check_int("bad swap target -> finalize stat", s, 1)
        call check_log("finalize errmsg names unknown state", &
                       index(m, "'ghost'") > 0, .true.)
    end subroutine test_swap_builder_errors

    ! A clean finalized engine (state "root" with a quit command).  intent(out)
    ! resets it, so callers get a fresh engine each time — needed because the
    ! sticky build error means a second failing op returns the FIRST message.
    subroutine fresh_finalized(e)
        type(engine_t), intent(out) :: e
        call e%add_state("root", prompt="> ")
        call e%add_command("root", "q(uit)", EDGE_QUIT)
        call e%finalize("root")
    end subroutine fresh_finalized

    ! A clean unfinalized engine with a single concrete state "s".
    subroutine fresh_state_s(e)
        type(engine_t), intent(out) :: e
        call e%add_state("s", prompt="> ")
    end subroutine fresh_state_s

    ! Byte-identity of build diagnostics is part of the three-language parity
    ! contract, so assert the EXACT strings (not substrings) that R3
    ! (builder_guard) and R4 (edge_kind_name / die_missing) must preserve.
    ! Every failing op runs on a fresh engine (sticky error would otherwise
    ! mask later messages).
    subroutine test_builder_error_messages_exact()
        type(engine_t)                :: e
        integer                       :: s
        character(len=:), allocatable :: m

        ! --- already-finalized, per op (finalize itself keeps the un-prefixed form) ---
        call fresh_finalized(e); call e%add_state("x", stat=s, errmsg=m)
        call check_str("add_state finalized msg", m, "cmdgraph: add_state: engine already finalized")
        call fresh_finalized(e); call e%add_command("root", "x(tra)", EDGE_QUIT, stat=s, errmsg=m)
        call check_str("add_command finalized msg", m, "cmdgraph: add_command: engine already finalized")
        call fresh_finalized(e); call e%add_include("root", "x", stat=s, errmsg=m)
        call check_str("add_include finalized msg", m, "cmdgraph: add_include: engine already finalized")
        call fresh_finalized(e); call e%set_on_enter("root", enter_detail, stat=s, errmsg=m)
        call check_str("set_on_enter finalized msg", m, "cmdgraph: set_on_enter: engine already finalized")
        call fresh_finalized(e); call e%finalize("root", stat=s, errmsg=m)
        call check_str("finalize finalized msg", m, "cmdgraph: engine already finalized")

        ! --- unknown state, per op that resolves one ---
        call fresh_state_s(e); call e%add_command("missing", "a", EDGE_QUIT, stat=s, errmsg=m)
        call check_str("add_command unknown-state msg", m, "cmdgraph: add_command: unknown state 'missing'")
        call fresh_state_s(e); call e%add_include("nosuch", "s", stat=s, errmsg=m)
        call check_str("add_include unknown-state msg", m, "cmdgraph: add_include: unknown state 'nosuch'")
        call fresh_state_s(e); call e%set_on_enter("gone", enter_detail, stat=s, errmsg=m)
        call check_str("set_on_enter unknown-state msg", m, "cmdgraph: set_on_enter: unknown state 'gone'")

        ! --- duplicate state (add_state's inverted lookup) ---
        block
            type(engine_t) :: d
            call d%add_state("home", prompt="> ")
            call d%add_state("home", stat=s, errmsg=m)
            call check_str("duplicate-state msg", m, "cmdgraph: state 'home' already added")
        end block

        ! --- die_missing, every kind/attr combination and first-error order ---
        call fresh_state_s(e); call e%add_command("s", "a(ct)", EDGE_ACTION, stat=s, errmsg=m)
        call check_str("action no-proc msg", m, "cmdgraph: action edge 'a(ct)' missing required proc")
        call fresh_state_s(e); call e%add_command("s", "g", EDGE_GOTO, stat=s, errmsg=m)
        call check_str("goto no-target msg", m, "cmdgraph: goto edge 'g' missing required target")
        call fresh_state_s(e); call e%add_command("s", "n", EDGE_SWAP, stat=s, errmsg=m)
        call check_str("swap no-target msg", m, "cmdgraph: swap edge 'n' missing required target")
        call fresh_state_s(e); call e%add_command("s", "dg", EDGE_DO_GOTO, proc=act_outer, stat=s, errmsg=m)
        call check_str("do_goto no-target msg", m, "cmdgraph: do_goto edge 'dg' missing required target")
        ! target present, proc absent -> proc error only (target is checked first)
        call fresh_state_s(e); call e%add_command("s", "dg2", EDGE_DO_GOTO, target="s", stat=s, errmsg=m)
        call check_str("do_goto no-proc msg", m, "cmdgraph: do_goto edge 'dg2' missing required proc")
        call fresh_state_s(e); call e%add_command("s", "ds", EDGE_DO_SWAP, proc=act_outer, stat=s, errmsg=m)
        call check_str("do_swap no-target msg", m, "cmdgraph: do_swap edge 'ds' missing required target")
        call fresh_state_s(e); call e%add_command("s", "ds2", EDGE_DO_SWAP, target="s", stat=s, errmsg=m)
        call check_str("do_swap no-proc msg", m, "cmdgraph: do_swap edge 'ds2' missing required proc")
        call fresh_state_s(e); call e%add_command("s", "c", EDGE_DO_POP, stat=s, errmsg=m)
        call check_str("do_pop no-proc msg", m, "cmdgraph: do_pop edge 'c' missing required proc")

        ! --- unknown edge kind ---
        call fresh_state_s(e); call e%add_command("s", "x", 999, stat=s, errmsg=m)
        call check_str("unknown edge-kind msg", m, "cmdgraph: unknown edge kind 999")
    end subroutine test_builder_error_messages_exact

    ! E5: exceed the initial states capacity (8) to exercise the doubling grow
    ! path and the finalize trim; every state must still resolve and dispatch.
    subroutine test_state_capacity_growth()
        type(engine_t)   :: e
        integer          :: i, s
        character(len=8) :: nm

        do i = 1, 12
            write(nm,'("s",i0)') i
            call e%add_state(trim(nm), prompt="> ")
            call e%add_command(trim(nm), "q(uit)", EDGE_QUIT)
        end do
        call e%add_command("s1", "g(o)", EDGE_GOTO, target="s2")
        call e%finalize("s1", stat=s)
        call check_int("12-state finalize ok",           s, 0)
        call check_int("states trimmed to exact count",  size(e%states), 12)
        call check_str("initial state resolves",         e%current_state(), "s1")
        call check_int("go transitions across grown set", e%dispatch("go"), RC_TRANSITIONED)
        call check_str("landed in s2",                   e%current_state(), "s2")
    end subroutine test_state_capacity_growth

    ! E2/R2: abbreviation matching through dispatch — every boundary resolved
    ! via the finalize-cached full — plus the exact ambiguous message.
    subroutine test_abbrev_boundaries()
        type(engine_t) :: e
        integer        :: s

        call e%add_state("root", prompt="> ")
        call e%add_command("root", "pr(int)", EDGE_ACTION, proc=act_outer)
        call e%finalize("root", stat=s)
        call check_int("abbrev finalize ok",    s,                     0)
        call check_int("exact-req matches",     e%dispatch("pr"),      RC_OK)
        call check_int("mid-abbrev matches",    e%dispatch("pri"),     RC_OK)
        call check_int("full-spec matches",     e%dispatch("print"),   RC_OK)
        call check_int("one-char-over no match", e%dispatch("prints"), RC_UNKNOWN)
        call check_int("sub-req no match",       e%dispatch("p"),      RC_UNKNOWN)

        block
            type(engine_t) :: e2
            call e2%add_state("root", prompt="> ")
            call e2%add_command("root", "s(ave)", EDGE_ACTION, proc=act_outer)
            call e2%add_command("root", "s(ync)", EDGE_ACTION, proc=act_outer)
            call e2%finalize("root")
            call check_int("shared prefix is ambiguous", e2%dispatch("s"), RC_AMBIGUOUS)
            call check_str("ambiguous message is canonical", e2%last_message, &
                           "ambiguous: s matches s(ave), s(ync)")
        end block
    end subroutine test_abbrev_boundaries

    ! E1: goto/swap/pop transitions resolve through the cached target_idx.
    subroutine test_target_idx_transitions()
        type(engine_t) :: e
        integer        :: s

        call e%add_state("a", prompt="a> ")
        call e%add_state("b", prompt="b> ")
        call e%add_command("a", "g(o)",   EDGE_GOTO, target="b")
        call e%add_command("a", "n(ext)", EDGE_SWAP, target="b")
        call e%add_command("b", "back",   EDGE_POP)
        call e%finalize("a", stat=s)
        call check_int("target_idx finalize ok",  s,                  0)
        call check_str("starts in a",              e%current_state(),  "a")
        call check_int("goto transitions",         e%dispatch("go"),   RC_TRANSITIONED)
        call check_str("goto landed in b",         e%current_state(),  "b")
        call check_int("pop returns",              e%dispatch("back"), RC_TRANSITIONED)
        call check_str("popped back to a",         e%current_state(),  "a")
        call check_int("swap transitions",         e%dispatch("next"), RC_TRANSITIONED)
        call check_str("swap replaced frame -> b", e%current_state(),  "b")
    end subroutine test_target_idx_transitions

    function act_typecheck(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        ! associate (ctx => ctx)   ! unused: inspects the parsed arg's node type
        n = args%get(1)
        if (.not. allocated(n)) then
            last_node_type = "<none>"
            return
        end if
        select type (n)
        type is (dlist_node_integer); last_node_type = "int"
        type is (dlist_node_real);    last_node_type = "real"
        type is (dlist_node_char);    last_node_type = "char"
        class default;                last_node_type = "?"
        end select
    end function act_typecheck

    ! E3: tokeniser edge cases driven through dispatch (the helpers are private).
    ! Covers the structural gaps the rewrite most affects, plus typed-token node
    ! landing and the E3d lead+rest suffix arithmetic.
    subroutine test_tokeniser_edges()
        type(engine_t) :: e
        integer        :: s, before

        call e%add_state("home", prompt="> ")
        call e%add_command("home", "a(ct)",  EDGE_ACTION, proc=act_outer)
        call e%add_command("home", "t(ype)", EDGE_ACTION, proc=act_typecheck)
        call e%add_command("home", "n(ote)", EDGE_ACTION, proc=act_rest, &
                           args=[arg_is_int("id"), arg_is_rest("body")])
        call e%finalize("home", stat=s)
        call check_int("tok finalize ok", s, 0)

        ! empty / all-delimiter lines: RC_OK, no action fired, state unchanged
        before = last_act_outer_called
        call check_int("empty line -> RC_OK",       e%dispatch(""),      RC_OK)
        call check_int("all-delimiter line -> RC_OK", e%dispatch("     "), RC_OK)
        call check_int("no action fired on blank",  last_act_outer_called, before)
        call check_str("blank leaves state",        e%current_state(),   "home")

        ! leading spaces before the command still resolve it
        before = last_act_outer_called
        call check_int("leading-space command -> RC_OK", e%dispatch("   act"), RC_OK)
        call check_int("leading-space command fired",    last_act_outer_called, before + 1)

        ! typed tokens land as the right node types (no arg spec -> raw parse)
        call check_int("int token ok",    e%dispatch("type 42"),    RC_OK)
        call check_str("42 -> int",       last_node_type, "int")
        call check_int("real token ok",   e%dispatch("type 1.5"),   RC_OK)
        call check_str("1.5 -> real",     last_node_type, "real")
        call check_int("minus token ok",  e%dispatch("type -3"),    RC_OK)
        call check_str("-3 -> int",       last_node_type, "int")
        call check_int("plus token ok",   e%dispatch("type +7"),    RC_OK)
        call check_str("+7 -> int",       last_node_type, "int")
        call check_int("d-exp token ok",  e%dispatch("type 1.5d0"), RC_OK)
        call check_str("1.5d0 -> real",   last_node_type, "real")
        call check_int("word token ok",   e%dispatch("type hello"), RC_OK)
        call check_str("hello -> char",   last_node_type, "char")

        ! multiple spaces between the lead arg and the rest tail (E3d): the
        ! tail's leading run is stripped, internal spacing preserved.
        call check_int("multi-space lead+rest -> RC_OK", &
            e%dispatch("note 5    buy  milk"), RC_OK)
        call check_int("lead int parsed",        last_rest_int, 5)
        call check_str("rest tail stripped+kept", last_rest_str, "buy  milk")

        ! rest command with no tokens: the lead walk exhausts immediately (empty
        ! tail), then validation reports the missing required lead arg.
        call check_int("bare rest command -> RC_ERROR",        e%dispatch("note"),     RC_ERROR)
        call check_int("blank-only rest command -> RC_ERROR",  e%dispatch("note    "), RC_ERROR)
    end subroutine test_tokeniser_edges

    ! on_enter probe: record the context handed to the hook and count fires.
    subroutine enter_record(ctx)
        character(len=*), intent(in) :: ctx
        hook_ctx_at_fire = ctx
        hook_fire_count  = hook_fire_count + 1
    end subroutine enter_record

    function act_ctx99(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        ! associate (args => args, ctx => ctx)   ! unused: fixed context
        rv = action_ok("99")
    end function act_ctx99

    function act_error_silent(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        ! associate (args => args, ctx => ctx)   ! unused
        rv = action_error()   ! errored, but no message
    end function act_error_silent

    ! R1 parity contract: on_enter fires AFTER the destination frame is in
    ! place (it is handed the NEW context), and swap/do_swap pop the old frame
    ! BEFORE pushing — so the resulting depth is +1 for goto/do_goto but
    ! unchanged for swap/do_swap.
    subroutine test_on_enter_ordering()
        type(engine_t) :: e
        integer        :: s, fires

        call e%add_state("root", prompt="r> ")
        call e%add_state("a",    prompt="a> ")
        call e%add_state("b",    prompt="b> ")
        call e%set_on_enter("a", enter_record)
        call e%set_on_enter("b", enter_record)
        call e%add_command("root", "g(o)", EDGE_GOTO,    target="a")
        call e%add_command("a", "j(ump)",  EDGE_DO_GOTO, target="b", proc=act_ctx99)
        call e%add_command("a", "s(wap)",  EDGE_SWAP,    target="b")
        call e%add_command("a", "d(swap)", EDGE_DO_SWAP, target="b", proc=act_ctx99)
        call e%add_command("b", "back",    EDGE_POP)
        call e%add_command("b", "z(ap)",   EDGE_SWAP,    target="a")
        call e%finalize("root", stat=s)
        call check_int("ordering finalize ok", s, 0)
        hook_fire_count = 0

        ! goto: push a -> depth 2, hook fires with empty context
        fires = hook_fire_count
        call check_int("go transitions",          e%dispatch("go"), RC_TRANSITIONED)
        call check_int("goto depth 2",            size(e%state_path()), 2)
        call check_int("goto fired on_enter once", hook_fire_count - fires, 1)
        call check_str("goto fires with empty ctx", hook_ctx_at_fire, "")

        ! do_goto: push b -> depth 3, hook fires with the new context "99"
        fires = hook_fire_count
        call check_int("do_goto transitions",       e%dispatch("jump"), RC_TRANSITIONED)
        call check_int("do_goto depth 3 (push)",    size(e%state_path()), 3)
        call check_int("do_goto fired on_enter once", hook_fire_count - fires, 1)
        call check_str("do_goto fires with new ctx", hook_ctx_at_fire, "99")

        ! pop back to a — POP fires no on_enter
        fires = hook_fire_count
        call check_int("pop back to a",  e%dispatch("back"), RC_TRANSITIONED)
        call check_str("back in a",      e%current_state(), "a")
        call check_int("pop fires no on_enter", hook_fire_count - fires, 0)

        ! swap: pop a then push b -> depth STAYS 2 (not 3), hook fires
        fires = hook_fire_count
        call check_int("swap transitions",          e%dispatch("swap"), RC_TRANSITIONED)
        call check_int("swap depth stays 2 (pop-then-push)", size(e%state_path()), 2)
        call check_int("swap fired on_enter once",  hook_fire_count - fires, 1)
        call check_str("swap fires with empty ctx", hook_ctx_at_fire, "")

        ! zap back to a (swap b->a), then do_swap: depth STAYS 2, context "99"
        call check_int("zap back to a", e%dispatch("zap"), RC_TRANSITIONED)
        fires = hook_fire_count
        call check_int("do_swap transitions",        e%dispatch("dswap"), RC_TRANSITIONED)
        call check_int("do_swap depth stays 2 (pop-then-push)", size(e%state_path()), 2)
        call check_int("do_swap fired on_enter once", hook_fire_count - fires, 1)
        call check_str("do_swap fires with new ctx", hook_ctx_at_fire, "99")
    end subroutine test_on_enter_ordering

    ! do_pop whose action errors must leave the frame in place (RC_ERROR, state
    ! and running-flag unchanged) — the pop happens only on success.
    subroutine test_do_pop_error_keeps_frame()
        type(engine_t) :: e
        call e%add_state("root",   prompt="> ")
        call e%add_state("detail", prompt="d> ")
        call e%add_command("root",   "g(o)",     EDGE_GOTO,   target="detail")
        call e%add_command("detail", "c(ommit)", EDGE_DO_POP, proc=act_bad_msg)
        call e%finalize("root")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)
        call check_int("enter detail",              e%dispatch("go"),     RC_TRANSITIONED)
        call check_int("do_pop error -> RC_ERROR",  e%dispatch("commit"), RC_ERROR)
        call check_str("frame kept (still in detail)", e%current_state(), "detail")
        call check_log("still running after do_pop error", e%is_running(), .true.)
    end subroutine test_do_pop_error_keeps_frame

    ! An action erroring with no message emits nothing but still returns
    ! RC_ERROR (guards the nested-if errmsg emission in invoke_proc).  A prior
    ! loud error seeds last_error; the silent error must not overwrite it.
    subroutine test_action_error_no_msg()
        type(engine_t)                :: e
        character(len=:), allocatable :: before
        call e%add_state("root", prompt="> ")
        call e%add_command("root", "loud",   EDGE_ACTION, proc=act_bad_msg)
        call e%add_command("root", "silent", EDGE_ACTION, proc=act_error_silent)
        call e%finalize("root")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)
        call check_int("loud action error -> RC_ERROR", e%dispatch("loud"), RC_ERROR)
        before = e%last_error
        call check_int("silent action error -> RC_ERROR", e%dispatch("silent"), RC_ERROR)
        call check_str("silent error emits nothing (last_error unchanged)", e%last_error, before)
    end subroutine test_action_error_no_msg

    function act_swap_pick(args, ctx) result(rv)
        ! id<=0 -> no value (veto the swap); else return "<id>" as context.
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
            if (n%data > 0) then
                write(buf, '(i0)') n%data
                rv%value = trim(buf)
            end if
        class default
            rv%errored = .true.
        end select
    end function act_swap_pick

    subroutine enter_swap_a(ctx)
        character(len=*), intent(in) :: ctx
        swap_enter_a = swap_enter_a + 1
    end subroutine enter_swap_a

    subroutine enter_swap_b(ctx)
        character(len=*), intent(in) :: ctx
        swap_enter_b = swap_enter_b + 1
        swap_ctx_b = ctx
    end subroutine enter_swap_b

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

    subroutine test_int_to_real_promotion()
        ! Typed ARG_REAL slot accepts an integer literal; the post-validate
        ! normaliser replaces the integer node with a real(8) node so the
        ! action receives a real-typed value. Parity with Tcl/C++.
        type(engine_t) :: e
        call e%add_state("root", prompt="> ")
        call e%add_command("root", "r(eal)", EDGE_ACTION, proc=act_real, &
                           args=[arg_is_real("x")])
        call e%finalize("root")
        call e%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)
        ! Decimal literal continues to work.
        last_real_arg = 0.0d0
        call check_int("typed real arg decimal → RC_OK", &
                       e%dispatch("real 3.14"), RC_OK)
        call check_log("typed real arg decimal value", &
                       last_real_arg > 3.13d0 .and. last_real_arg < 3.15d0, .true.)
        ! Integer literal is promoted to real(8) and the action sees a real
        ! node, not an integer node.
        last_real_arg = 0.0d0
        call check_int("typed real arg accepts int (promoted) → RC_OK", &
                       e%dispatch("real 7"), RC_OK)
        call check_log("typed real arg int-promoted value", &
                       last_real_arg == 7.0d0, .true.)
    end subroutine test_int_to_real_promotion

end program utest_cmdgraph
