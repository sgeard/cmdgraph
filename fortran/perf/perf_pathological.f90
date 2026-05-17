! perf_pathological.f90 — demonstrates the two scaling bottlenecks
!
! Construction: add_command writes into a capacity-doubling over-allocated
! commands(:) array (initial capacity 8, doubling via move_alloc when full).
! finalize trims each state to the exact count in one reallocation (O(N) total).
!
! Dispatch: find_matches must scan the entire command list of the current state
! to detect ambiguity, performing three allocatable character assignments per
! entry (req, opt, full).  Every dispatch is therefore O(N) heap allocations
! regardless of which command was typed.
!
! For interactive use these costs are immaterial -- graphs have tens of commands
! per state and dispatch happens at human speed.  This program makes them
! visible by scaling N to the point where the time becomes measurable, then
! shows the same workload on a realistic-sized graph.
!
! Build and run:  make -C .. F=ifx perf
!            or:  make -C .. F=gfortran perf

module perf_procs
    use cmdgraph
    use dlist
    implicit none
contains
    function act_noop(args, ctx) result(rv)
        type(dlist_t), intent(in)    :: args
        character(len=*), intent(in) :: ctx
        type(action_result_t)        :: rv
    end function act_noop

    subroutine build_engine(eng, n)
        type(engine_t), intent(out) :: eng
        integer,        intent(in)  :: n
        integer          :: i
        character(len=7) :: spec     ! "c" + 5-digit zero-padded number = 6 chars
        call eng%add_state("root", prompt="> ")
        do i = 1, n
            write(spec, '("c",i5.5)') i    ! c00001, c00002, ..., cNNNNN
            call eng%add_command("root", trim(spec), EDGE_ACTION, proc=act_noop)
        end do
        call eng%finalize("root")
        call eng%set_io_units(output_unit=QUIET_UNIT, error_unit=QUIET_UNIT)
    end subroutine build_engine
end module perf_procs

program perf_pathological
    use cmdgraph
    use perf_procs
    implicit none

    ! --- Tune to taste ---
    ! At N=5000, D=100000 on a modern desktop (ifx -O3) the pathological
    ! dispatch phase takes ~13 s; the realistic phase takes < 0.1 s.
    integer, parameter :: N_BIG      = 5000    ! pathological: commands per state
    integer, parameter :: N_SMALL    = 20      ! realistic:    commands per state
    integer, parameter :: D          = 100000  ! dispatches per timing phase

    type(engine_t) :: eng
    integer        :: i, rc
    real           :: t0, t1

    write(*, '(/,a,/)') "=== pathological case (N=" // itoa(N_BIG) // ") ==="

    ! -- Construction O(N) --
    ! add_command writes into a capacity-doubling commands(:) array.
    ! finalize trims each state to the exact count: O(N) total.
    call cpu_time(t0)
    call build_engine(eng, N_BIG)
    call cpu_time(t1)
    write(*, '(a,f7.3,a)') "  construction (add_command x " // itoa(N_BIG) // "):  ", &
        t1 - t0, " s   [O(N)]"

    ! -- Dispatch O(N) per call --
    ! find_matches scans all N entries every call; note that "best" and "worst"
    ! command positions make no difference -- there is no early exit because the
    ! full scan is needed for ambiguity detection.
    call cpu_time(t0)
    do i = 1, D
        rc = eng%dispatch("c00001")   ! first command in the list
    end do
    call cpu_time(t1)
    write(*, '(a,f7.3,a)') "  dispatch x " // itoa(D) // ":                        ", &
        t1 - t0, " s   [O(N x D)]"

    write(*, '(/,a,/)') "=== realistic case (N=" // itoa(N_SMALL) // ") ==="

    call cpu_time(t0)
    call build_engine(eng, N_SMALL)
    call cpu_time(t1)
    write(*, '(a,f7.3,a)') "  construction (add_command x " // itoa(N_SMALL) // "):   ", &
        t1 - t0, " s"

    call cpu_time(t0)
    do i = 1, D
        rc = eng%dispatch("c00001")
    end do
    call cpu_time(t1)
    write(*, '(a,f7.3,a)') "  dispatch x " // itoa(D) // ":                        ", &
        t1 - t0, " s"

contains
    pure function itoa(n) result(s)
        integer, intent(in)           :: n
        character(len=:), allocatable :: s
        character(len=20)             :: buf
        write(buf, '(i0)') n
        s = trim(buf)
    end function itoa

end program perf_pathological
