!! SPDX-License-Identifier: MIT
!! Copyright (c) 2026 Simon Geard
!!
! Tests for cmdgraph's DAG validation: the structural graph formed by
! goto/do_goto edges between concrete states must be acyclic. Construction
! errors are returned via the optional stat/errmsg arguments to finalize.
program utest_dag
    use cmdgraph
    use dlist
    implicit none

    integer :: pass = 0, fail = 0

    call test_self_loop_goto()
    call test_self_loop_do_goto()
    call test_two_cycle()
    call test_three_cycle()
    call test_valid_dag_no_cycle()
    call test_stat_zero_on_success()
    call test_errmsg_unallocated_on_success()
    call test_pop_does_not_form_cycle()
    call test_swap_does_not_form_cycle()

    write(*,'(/,a,i0,a,i0,a,i0,a)') "DAG tests: ", pass+fail, " total, ", &
                                    pass, " passed, ", fail, " failed"
    if (fail > 0) error stop 1

contains

    function noop(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
    end function noop

    subroutine test_self_loop_goto()
        type(engine_t)                :: eng
        integer                       :: stat
        character(len=:), allocatable :: msg
        call eng%add_state("a", prompt="a> ")
        call eng%add_command("a", "loop", EDGE_GOTO, target="a")
        call eng%finalize("a", stat=stat, errmsg=msg)
        call expect_err("self-loop via goto", stat, msg, "a -> a")
    end subroutine test_self_loop_goto

    subroutine test_self_loop_do_goto()
        type(engine_t)                :: eng
        integer                       :: stat
        character(len=:), allocatable :: msg
        call eng%add_state("a", prompt="a> ")
        call eng%add_command("a", "loop", EDGE_DO_GOTO, target="a", proc=noop)
        call eng%finalize("a", stat=stat, errmsg=msg)
        call expect_err("self-loop via do_goto", stat, msg, "a -> a")
    end subroutine test_self_loop_do_goto

    subroutine test_two_cycle()
        type(engine_t)                :: eng
        integer                       :: stat
        character(len=:), allocatable :: msg
        call eng%add_state("a", prompt="a> ")
        call eng%add_state("b", prompt="b> ")
        call eng%add_command("a", "to_b", EDGE_GOTO, target="b")
        call eng%add_command("b", "to_a", EDGE_GOTO, target="a")
        call eng%finalize("a", stat=stat, errmsg=msg)
        call expect_err("two-cycle a->b->a", stat, msg, "a -> b -> a")
    end subroutine test_two_cycle

    subroutine test_three_cycle()
        type(engine_t)                :: eng
        integer                       :: stat
        character(len=:), allocatable :: msg
        call eng%add_state("a", prompt="a> ")
        call eng%add_state("b", prompt="b> ")
        call eng%add_state("c", prompt="c> ")
        call eng%add_command("a", "to_b", EDGE_GOTO,    target="b")
        call eng%add_command("b", "to_c", EDGE_DO_GOTO, target="c", proc=noop)
        call eng%add_command("c", "to_a", EDGE_GOTO,    target="a")
        call eng%finalize("a", stat=stat, errmsg=msg)
        call expect_err("three-cycle a->b->c->a", stat, msg, "a -> b -> c -> a")
    end subroutine test_three_cycle

    subroutine test_valid_dag_no_cycle()
        type(engine_t)                :: eng
        integer                       :: stat
        character(len=:), allocatable :: msg
        call eng%add_state("root",  prompt="r> ")
        call eng%add_state("left",  prompt="l> ")
        call eng%add_state("right", prompt="rt> ")
        call eng%add_state("leaf",  prompt="lf> ")
        call eng%add_command("root",  "l", EDGE_GOTO, target="left")
        call eng%add_command("root",  "r", EDGE_GOTO, target="right")
        call eng%add_command("left",  "x", EDGE_GOTO, target="leaf")
        call eng%add_command("right", "x", EDGE_GOTO, target="leaf")
        call eng%add_command("leaf",  "b", EDGE_POP)
        call eng%finalize("root", stat=stat, errmsg=msg)
        call expect_ok("tree-shaped DAG accepted", stat, msg)
    end subroutine test_valid_dag_no_cycle

    subroutine test_stat_zero_on_success()
        type(engine_t)                :: eng
        integer                       :: stat
        call eng%add_state("solo", prompt="> ")
        call eng%add_command("solo", "q", EDGE_QUIT)
        call eng%finalize("solo", stat=stat)
        call expect_int("stat=0 on success", stat, 0)
    end subroutine test_stat_zero_on_success

    subroutine test_errmsg_unallocated_on_success()
        type(engine_t)                :: eng
        integer                       :: stat
        character(len=:), allocatable :: msg
        call eng%add_state("solo", prompt="> ")
        call eng%add_command("solo", "q", EDGE_QUIT)
        call eng%finalize("solo", stat=stat, errmsg=msg)
        call expect_log("errmsg unallocated on success", .not. allocated(msg), .true.)
    end subroutine test_errmsg_unallocated_on_success

    subroutine test_pop_does_not_form_cycle()
        ! pop is the return path; an a→b→pop chain is a valid hierarchy, not a cycle.
        type(engine_t)                :: eng
        integer                       :: stat
        character(len=:), allocatable :: msg
        call eng%add_state("a", prompt="a> ")
        call eng%add_state("b", prompt="b> ")
        call eng%add_command("a", "down", EDGE_GOTO, target="b")
        call eng%add_command("b", "up",   EDGE_POP)
        call eng%finalize("a", stat=stat, errmsg=msg)
        call expect_ok("pop is not a cycle edge", stat, msg)
    end subroutine test_pop_does_not_form_cycle

    subroutine test_swap_does_not_form_cycle()
        ! swap/do_swap replace the top frame (pop-then-push) so a mutually
        ! swapping a<->b pair is inherently cyclic yet valid — exempt from the check.
        type(engine_t)                :: eng
        integer                       :: stat
        character(len=:), allocatable :: msg
        call eng%add_state("a", prompt="a> ")
        call eng%add_state("b", prompt="b> ")
        call eng%add_command("a", "toB", EDGE_SWAP, target="b")
        call eng%add_command("b", "toA", EDGE_DO_SWAP, target="a", proc=noop)
        call eng%finalize("a", stat=stat, errmsg=msg)
        call expect_ok("swap/do_swap are not cycle edges", stat, msg)
    end subroutine test_swap_does_not_form_cycle

    ! ===== assertions =====

    subroutine expect_err(label, stat, msg, must_contain)
        character(len=*), intent(in)              :: label, must_contain
        integer, intent(in)                       :: stat
        character(len=:), allocatable, intent(in) :: msg
        if (stat == 0) then
            write(*,'(a)') "FAIL: " // label // " (expected non-zero stat, got 0)"
            fail = fail + 1
            return
        end if
        if (.not. allocated(msg)) then
            write(*,'(a)') "FAIL: " // label // " (errmsg not allocated)"
            fail = fail + 1
            return
        end if
        if (index(msg, "cycle detected") == 0) then
            write(*,'(a)') "FAIL: " // label // " (msg missing 'cycle detected': '" // msg // "')"
            fail = fail + 1
            return
        end if
        if (index(msg, must_contain) == 0) then
            write(*,'(a)') "FAIL: " // label // " (msg missing '" // must_contain // "': '" // msg // "')"
            fail = fail + 1
            return
        end if
        write(*,'(a)') "PASS: " // label // " — " // msg
        pass = pass + 1
    end subroutine expect_err

    subroutine expect_ok(label, stat, msg)
        character(len=*), intent(in)              :: label
        integer, intent(in)                       :: stat
        character(len=:), allocatable, intent(in) :: msg
        if (stat /= 0) then
            if (allocated(msg)) then
                write(*,'(a,i0,a)') "FAIL: " // label // " (stat=", stat, ", msg='" // msg // "')"
            else
                write(*,'(a,i0,a)') "FAIL: " // label // " (stat=", stat, ", no msg)"
            end if
            fail = fail + 1
            return
        end if
        write(*,'(a)') "PASS: " // label
        pass = pass + 1
    end subroutine expect_ok

    subroutine expect_int(label, got, expected)
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
    end subroutine expect_int

    subroutine expect_log(label, got, expected)
        character(len=*), intent(in) :: label
        logical, intent(in)          :: got, expected
        if (got .eqv. expected) then
            write(*,'(a)') "PASS: " // label
            pass = pass + 1
        else
            write(*,'(a)') "FAIL: " // label
            fail = fail + 1
        end if
    end subroutine expect_log

end program utest_dag
