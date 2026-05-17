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
    call test_iteration()
    call test_array_and_matrix_nodes()
    call test_finalize_on_scope_exit()

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

        call a%insert(0, int_node(2))
        call a%insert(0, int_node(1))
        call a%insert(2, int_node(4))
        call a%insert(2, int_node(3))
        call check_int("insert builds list size", a%size(), 4)
        call check_int_node("insert prepend", a, 1, 1)
        call check_int_node("insert middle", a, 3, 3)
        call check_int_node("insert append", a, 4, 4)

        call a%remove(1)
        call check_int_node("remove first", a, 1, 2)
        call a%remove(2)
        call check_int_node("remove middle", a, 2, 4)
        call a%remove(2)
        call check_int("remove last leaves one", a%size(), 1)
        call check_int_node("remaining node after removes", a, 1, 2)
    end subroutine test_insert_and_remove

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
