!! SPDX-License-Identifier: MIT
!! Copyright (c) 2026 Simon Geard
!!
program utest_dlist
    use dlist
    implicit none

    integer :: pass = 0, fail = 0
    integer, save :: iter_count = 0
    integer, save :: iter_sum = 0
    character(len=:), allocatable, save :: iter_seen

    call test_assignment_deep_copies_nodes()
    call test_self_assignment_preserves_nodes()
    call test_insert_and_remove()
    call test_replace()
    call test_iteration()
    call test_array_and_matrix_nodes()
    call test_finalize_on_scope_exit()
    call test_print_to_scratch_unit()

    write(*,'(/,a,i0,a,i0,a,i0,a)') "dlist tests: ", pass+fail, " total, ", &
                                    pass, " passed, ", fail, " failed"
    if (fail > 0) error stop 1

contains

    subroutine test_assignment_deep_copies_nodes()
        type(dlist_t) :: a, b

        call a%append(int_node(1))
        call a%append(char_node("alpha"))

        b = a
        call check_int("copy has original size", b%size(), 2)

        call a%clear()
        call check_int("clear source leaves copy size", b%size(), 2)
        call check_int_node("copied int node retained", b, 1, 1)
        call check_char_node("copied char node retained", b, 2, "alpha")
    end subroutine test_assignment_deep_copies_nodes

    subroutine test_self_assignment_preserves_nodes()
        type(dlist_t) :: a

        call a%append(int_node(7))
        call a%append(char_node("self"))

        a = a
        call check_int("self assignment preserves size", a%size(), 2)
        call check_int_node("self assignment preserves int", a, 1, 7)
        call check_char_node("self assignment preserves char", a, 2, "self")
    end subroutine test_self_assignment_preserves_nodes

    subroutine test_insert_and_remove()
        type(dlist_t) :: a

        ! 1-based insert-before semantics: insert(i, x) places x AT position i,
        ! shifting later elements right. idx<=1 (or empty) prepends; idx>size
        ! appends. (Codex #3: implementation now matches the documented API.)
        call a%insert(5, int_node(99))   ! empty list, any idx -> [99]
        call a%insert(1, int_node(10))   ! prepend           -> [10,99]
        call a%insert(99, int_node(40))  ! idx>size: append   -> [10,99,40]
        call a%insert(2, int_node(20))   ! before pos 2       -> [10,20,99,40]
        call a%insert(3, int_node(30))   ! before pos 3       -> [10,20,30,99,40]
        call check_int("insert builds list size", a%size(), 5)
        call check_int_node("insert: prepend at head",        a, 1, 10)
        call check_int_node("insert: before-idx at pos 2",    a, 2, 20)
        call check_int_node("insert: before-idx keeps order", a, 3, 30)
        call check_int_node("insert: shifted element survives", a, 4, 99)
        call check_int_node("insert: append at tail",         a, 5, 40)

        call a%remove(1)
        call check_int_node("remove first", a, 1, 20)
        call a%remove(3)
        call check_int_node("remove middle", a, 3, 40)
        call a%remove(99)
        call check_int("remove out-of-range is a no-op", a%size(), 3)
        call a%remove(2)
        call check_int("remove leaves two", a%size(), 2)
        call check_int_node("remaining head after removes", a, 1, 20)
        call check_int_node("remaining tail after removes", a, 2, 40)
    end subroutine test_insert_and_remove

    ! E4: in-place replace at 1-based index, including a type-changing
    ! replacement, an out-of-range no-op, and size invariance.
    subroutine test_replace()
        type(dlist_t)                         :: a
        class(dlist_node_data_t), allocatable :: node

        call a%append(int_node(10))
        call a%append(int_node(20))
        call a%append(int_node(30))

        call a%replace(1, int_node(11))         ! first
        call a%replace(3, int_node(33))         ! last
        call a%replace(2, real_node(2.5_dp))    ! middle, int -> real (type change)
        call check_int("replace keeps size", a%size(), 3)
        call check_int_node("replace first", a, 1, 11)
        call check_int_node("replace last",  a, 3, 33)

        node = a%get(2)
        select type (node)
        type is (dlist_node_real)
            call check_log("replace changed node type to real", .true., .true.)
            call check_log("replaced real value", node%data == 2.5_dp, .true.)
        class default
            call check_log("replace changed node type to real", .false., .true.)
        end select

        call a%replace(0,  int_node(99))        ! out of range low  -> no-op
        call a%replace(4,  int_node(99))        ! out of range high -> no-op
        call check_int("replace out-of-range keeps size", a%size(), 3)
        call check_int_node("replace low no-op leaves head",  a, 1, 11)
        call check_int_node("replace high no-op leaves tail", a, 3, 33)
    end subroutine test_replace

    subroutine test_iteration()
        type(dlist_t) :: a
        logical :: ok

        call a%append(int_node(1))
        call a%append(int_node(2))
        call a%append(int_node(3))

        iter_count = 0
        iter_sum = 0
        ok = a%iterate(count_until_two)
        call check_log("iterate can stop early", ok, .false.)
        call check_int("iterate early count", iter_count, 2)
        call check_int("iterate early sum", iter_sum, 3)

        iter_seen = ""
        ok = a%reverse_iterate(record_reverse)
        call check_log("reverse iterate completes", ok, .true.)
        call check_str("reverse iterate order", iter_seen, "321")
    end subroutine test_iteration

    subroutine test_array_and_matrix_nodes()
        type(dlist_t) :: a
        real(8) :: vec(3), mat(2,2)
        class(dlist_node_data_t), allocatable :: node

        vec = [1.0d0, 2.0d0, 3.0d0]
        mat = reshape([1.0d0, 2.0d0, 3.0d0, 4.0d0], [2, 2])
        call a%append(real_a_node(vec))
        call a%append(real_m_node(mat))

        node = a%get(1)
        select type (node)
        type is (dlist_node_real_a)
            call check_int("real array node size", size(node%data), 3)
            call check_log("real array node value", node%data(3) == 3.0d0, .true.)
        class default
            call fail_check("real array node type")
        end select

        node = a%get(2)
        select type (node)
        type is (dlist_node_real_m)
            call check_int("real matrix node rows", size(node%data, 1), 2)
            call check_int("real matrix node cols", size(node%data, 2), 2)
            call check_log("real matrix node value", node%data(2,2) == 4.0d0, .true.)
        class default
            call fail_check("real matrix node type")
        end select
    end subroutine test_array_and_matrix_nodes

    subroutine test_finalize_on_scope_exit()
        call build_and_leave_scope()
        call check_log("finalized scoped list without error", .true., .true.)
    end subroutine test_finalize_on_scope_exit

    subroutine test_print_to_scratch_unit()
        ! print_ll renders each built-in node kind to the given unit; redirect
        ! to a scratch file so we can assert content without polluting stdout.
        type(dlist_t)                 :: lst, empty
        integer                       :: u, ios, nlines
        character(len=256)            :: buf
        logical                       :: saw_int, saw_real, saw_char, saw_a, saw_m, saw_header

        open(newunit=u, status='scratch', action='readwrite', iostat=ios)
        call check_int("scratch unit open ok", ios, 0)

        call empty%print(unit=u)
        call lst%append(int_node(42))
        call lst%append(real_node(3.5d0))
        call lst%append(char_node("hello"))
        call lst%append(real_a_node([1.0d0, 2.0d0, 3.0d0]))
        call lst%append(real_m_node(reshape([1.0d0,2.0d0,3.0d0,4.0d0], [2,2])))
        call lst%print(unit=u)

        rewind(u)
        nlines     = 0
        saw_header = .false.
        saw_int    = .false.; saw_real = .false.; saw_char = .false.
        saw_a      = .false.; saw_m    = .false.
        scan_lines: do
            read(u, '(a)', iostat=ios) buf
            if (ios /= 0) exit scan_lines
            nlines = nlines + 1
            if (index(buf, 'Nodes:')           > 0) saw_header = .true.
            if (index(buf, 'int    = 42')      > 0) saw_int    = .true.
            if (index(buf, 'real   = 3.5')     > 0) saw_real   = .true.
            if (index(buf, 'char   = hello')   > 0) saw_char   = .true.
            if (index(buf, 'real_a =')         > 0) saw_a      = .true.
            if (index(buf, 'real_m = [2 x 2')  > 0) saw_m      = .true.
        end do scan_lines
        close(u)

        call check_log("print emits header",        saw_header, .true.)
        call check_log("print emits int node",      saw_int,    .true.)
        call check_log("print emits real node",     saw_real,   .true.)
        call check_log("print emits char node",     saw_char,   .true.)
        call check_log("print emits real array",    saw_a,      .true.)
        call check_log("print emits real matrix",   saw_m,      .true.)
    end subroutine test_print_to_scratch_unit

    subroutine build_and_leave_scope()
        type(dlist_t) :: tmp
        call tmp%append(real_node(1.5d0))
        call tmp%append(char_node("scoped"))
    end subroutine build_and_leave_scope

    subroutine count_until_two(node, ok)
        class(dlist_node_data_t), intent(in) :: node
        logical, intent(out)                 :: ok
        ok = .true.
        select type (node)
        type is (dlist_node_integer)
            iter_count = iter_count + 1
            iter_sum = iter_sum + node%data
            if (node%data == 2) ok = .false.
        class default
            ok = .false.
        end select
    end subroutine count_until_two

    subroutine record_reverse(node, ok)
        class(dlist_node_data_t), intent(in) :: node
        logical, intent(out)                 :: ok
        character(len=16) :: buf
        ok = .true.
        select type (node)
        type is (dlist_node_integer)
            write(buf, '(i0)') node%data
            iter_seen = iter_seen // trim(buf)
        class default
            ok = .false.
        end select
    end subroutine record_reverse

    subroutine check_int_node(label, lst, idx, expected)
        character(len=*), intent(in) :: label
        type(dlist_t), intent(in)    :: lst
        integer, intent(in)          :: idx, expected
        class(dlist_node_data_t), allocatable :: node

        node = lst%get(idx)
        select type (node)
        type is (dlist_node_integer)
            call check_int(label, node%data, expected)
        class default
            call fail_check(label)
        end select
    end subroutine check_int_node

    subroutine check_char_node(label, lst, idx, expected)
        character(len=*), intent(in) :: label, expected
        type(dlist_t), intent(in)    :: lst
        integer, intent(in)          :: idx
        class(dlist_node_data_t), allocatable :: node

        node = lst%get(idx)
        select type (node)
        type is (dlist_node_char)
            call check_str(label, node%data, expected)
        class default
            call fail_check(label)
        end select
    end subroutine check_char_node

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

    subroutine check_log(label, got, expected)
        character(len=*), intent(in) :: label
        logical, intent(in)          :: got, expected
        if (got .eqv. expected) then
            write(*,'(a)') "PASS: " // label
            pass = pass + 1
        else
            call fail_check(label)
        end if
    end subroutine check_log

    subroutine fail_check(label)
        character(len=*), intent(in) :: label
        write(*,'(a)') "FAIL: " // label
        fail = fail + 1
    end subroutine fail_check

end program utest_dlist
