!! SPDX-License-Identifier: MIT
!! Copyright (c) 2026 Simon Geard
!!
! Parity runner — Fortran.  Usage: runner_f <script> <result-file>
! Builds the canonical parity graph (see GRAPH.md), run_file the script with
! echo on, writes the normalised structured trailer to <result-file>.

module parity_procs
    use cmdgraph
    use dlist
    implicit none
contains

    function arg_i(args, n) result(v)
        type(dlist_t), intent(in)             :: args
        integer, intent(in)                   :: n
        integer                               :: v
        class(dlist_node_data_t), allocatable :: nd
        v = 0
        nd = args%get(n)
        select type (nd)
        type is (dlist_node_integer); v = nd%data
        end select
    end function arg_i

    function arg_s(args, n) result(v)
        type(dlist_t), intent(in)             :: args
        integer, intent(in)                   :: n
        character(len=:), allocatable         :: v
        class(dlist_node_data_t), allocatable :: nd
        v = ""
        nd = args%get(n)
        select type (nd)
        type is (dlist_node_char); v = nd%data
        end select
    end function arg_s

    function act_echo(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        write(*,'(2a)') "echo: ", arg_s(args, 1)
        rv = action_ok()
    end function act_echo

    function act_add(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        write(*,'(a,i0)') "sum: ", arg_i(args, 1) + arg_i(args, 2)
        rv = action_ok()
    end function act_add

    function act_save(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        write(*,'(a)') "save: ok"
        rv = action_ok()
    end function act_save

    function act_send(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        write(*,'(a)') "send: ok"
        rv = action_ok()
    end function act_send

    function act_scale(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        write(*,'(a)') "scale: ok"
        rv = action_ok()
    end function act_scale

    function act_open(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        integer                      :: id
        character(len=16)            :: buf
        id = arg_i(args, 1)
        if (id <= 0) then
            rv = action_ok()
        else
            write(buf,'(i0)') id
            rv = action_ok(trim(buf))
        end if
    end function act_open

    function act_zero(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        rv = action_ok("0")
    end function act_zero

    function act_where(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        write(*,'(2a)') "where: ctx=", ctx
        rv = action_ok()
    end function act_where

    function act_update(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
        write(*,'(2a)') "update: ", arg_s(args, 1)
        rv = action_ok()
    end function act_update

    subroutine enter_detail(ctx)
        character(len=*), intent(in) :: ctx
        write(*,'(2a)') "entered detail ctx=", ctx
    end subroutine enter_detail

end module parity_procs


program runner_f
    use cmdgraph
    use parity_procs
    implicit none

    type(engine_t)                :: eng
    character(len=4096)           :: script, resfile
    integer                       :: st, ln, u, nargs
    logical                       :: ok
    character(len=:), allocatable :: em, rc, lmsg, lerr

    nargs = command_argument_count()
    if (nargs < 2) then
        write(*,'(a)') "usage: runner_f <script> <result-file>"
        stop 2
    end if
    call get_command_argument(1, script)
    call get_command_argument(2, resfile)

    call eng%add_state("root", prompt="root> ")
    call eng%add_command("root", "e(cho)",  EDGE_ACTION,  proc=act_echo, &
                         help="echo text", args=[arg_is_rest("text")])
    call eng%add_command("root", "ad(d)",   EDGE_ACTION,  proc=act_add, &
                         help="add two ints", args=[arg_is_int("x"), arg_is_int("y")])
    call eng%add_command("root", "s(ave)",  EDGE_ACTION,  proc=act_save, help="save")
    call eng%add_command("root", "s(end)",  EDGE_ACTION,  proc=act_send, help="send")
    call eng%add_command("root", "sc(ale)", EDGE_ACTION,  proc=act_scale, &
                         help="scale", args=[arg_is_real("f")])
    call eng%add_command("root", "o(pen)",  EDGE_DO_GOTO, target="detail", &
                         proc=act_open, help="open id", args=[arg_is_int("id")])
    call eng%add_command("root", "z(ero)",  EDGE_DO_GOTO, target="detail", &
                         proc=act_zero, help="zero-ctx do_goto")
    call eng%add_command("root", "g(o)",    EDGE_GOTO,    target="detail", help="go")
    call eng%add_command("root", "q(uit)",  EDGE_QUIT,    help="quit")

    call eng%add_state("detail", prompt="detail> ")
    call eng%set_on_enter("detail", enter_detail)
    call eng%add_command("detail", "w(here)",  EDGE_ACTION, proc=act_where, &
                         help="show context")
    call eng%add_command("detail", "u(pdate)", EDGE_DO_POP, proc=act_update, &
                         help="update note", args=[arg_is_rest("note")])
    call eng%add_command("detail", "b(ack)",   EDGE_POP,    help="back")
    call eng%add_command("detail", "q(uit)",   EDGE_QUIT,   help="quit")

    call eng%finalize("root")

    st = RC_OK
    ln = 0
    ok = eng%run_file(trim(script), echo=.true., stat=st, errmsg=em, line=ln)

    if ((.not. ok) .and. ln == 0) then
        rc = "OPEN_FAIL"
    else if (ok) then
        rc = "OK"
    else
        select case (st)
        case (RC_UNKNOWN);      rc = "UNKNOWN"
        case (RC_AMBIGUOUS);    rc = "AMBIGUOUS"
        case (RC_TRANSITIONED); rc = "TRANSITIONED"
        case (RC_EXITED);       rc = "EXITED"
        case (RC_ERROR);        rc = "ERROR"
        case default;           rc = "OK"
        end select
    end if

    lmsg = ""
    if (allocated(eng%last_message)) lmsg = eng%last_message
    lerr = ""
    if (allocated(eng%last_error))   lerr = eng%last_error

    open(newunit=u, file=trim(resfile), status="replace", action="write")
    write(u,'(a,i0)') "ok=", merge(1, 0, ok)
    write(u,'(2a)')   "rc=", rc
    write(u,'(a,i0)') "line=", ln
    write(u,'(2a)')   "state=", eng%current_state()
    write(u,'(2a)')   "last_message=", lmsg
    write(u,'(2a)')   "last_error=", lerr
    close(u)
end program runner_f
