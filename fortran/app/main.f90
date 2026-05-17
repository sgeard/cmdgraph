! cmdgraph_f demo — a tiny interactive "library" REPL.
!
! Showcases:
!   - Prefix matching (s(elect), o(pen), …)
!   - Typed args: `open 2` passes an integer node; `find pragmatic` passes a string
!   - do_goto with a context: opening a book transitions to a per-book state
!     carrying the book id as context
!   - on_enter hook: auto-prints the title when you arrive in the book state
!   - Multi-state nav: q(uit), b(ack), pop

module library
    use cmdgraph
    use dlist
    implicit none

    ! Three sample books. Index = id.
    integer, parameter            :: N_BOOKS = 3
    character(len=*), parameter   :: titles(N_BOOKS) = [character(len=60) :: &
        "The Pragmatic Programmer",                                          &
        "Structure and Interpretation of Computer Programs",                 &
        "The C Programming Language"                                         ]
    character(len=*), parameter   :: summaries(N_BOOKS) = [character(len=120) :: &
        "Hunt & Thomas's tour of practical software craft.",                     &
        "The SICP — abstractions, procedures, the meta-circular evaluator.",     &
        "K&R — the book that taught a generation what a pointer is."             ]

contains

    function act_list(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        integer                               :: i
        do i = 1, N_BOOKS
            write(*,'(2x,i0,2x,a)') i, trim(titles(i))
        end do
    end function act_list

    function act_open(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        integer                               :: id
        character(len=16)                     :: buf
        character(len=40)                     :: msg

        n = args%get(1)
        select type (n)
        type is (dlist_node_integer)
            id = n%data
            if (id < 1 .or. id > N_BOOKS) then
                write(msg,'("no book with id ",i0," (try `list`)")') id
                rv = action_error(trim(msg))
                return
            end if
            write(buf,'(i0)') id
            rv = action_ok(trim(buf))
        end select
    end function act_open

    function act_find(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        integer                               :: i, hits
        character(len=:), allocatable         :: needle

        n = args%get(1)
        select type (n)
        type is (dlist_node_char)
            needle = lower(n%data)
            hits = 0
            do i = 1, N_BOOKS
                if (index(lower(trim(titles(i))), needle) > 0) then
                    write(*,'(2x,i0,2x,a)') i, trim(titles(i))
                    hits = hits + 1
                end if
            end do
            if (hits == 0) write(*,'(a)') "  (no matches)"
        end select
    end function act_find

    function act_hello(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        write(*,'(a)') "Welcome to the library."
    end function act_hello

    function act_read(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        integer                               :: id, iostat
        read(ctx, *, iostat=iostat) id
        if (iostat /= 0) then
            rv = action_error()
            return
        end if
        write(*,'(a)') trim(summaries(id))
    end function act_read

    function act_title(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        integer                               :: id, iostat
        read(ctx, *, iostat=iostat) id
        if (iostat /= 0) then
            rv = action_error()
            return
        end if
        write(*,'(a)') trim(titles(id))
    end function act_title

    subroutine enter_book(ctx)
        character(len=*), intent(in)          :: ctx
        integer                               :: id, iostat
        read(ctx, *, iostat=iostat) id
        if (iostat == 0 .and. id >= 1 .and. id <= N_BOOKS) then
            write(*,'(a,a)') "Opened: ", trim(titles(id))
        end if
    end subroutine enter_book

    pure function lower(s) result(r)
        character(len=*), intent(in)          :: s
        character(len=len(s))                 :: r
        integer                               :: i, c
        do i = 1, len(s)
            c = iachar(s(i:i))
            if (c >= iachar('A') .and. c <= iachar('Z')) then
                r(i:i) = achar(c + 32)
            else
                r(i:i) = s(i:i)
            end if
        end do
    end function lower

end module library


program library_demo
    use cmdgraph
    use library
    implicit none

    type(engine_t) :: eng

    ! Library state
    call eng%add_state("library", prompt="library> ")
    call eng%add_command("library", "h(ello)", EDGE_ACTION,  proc=act_hello, help="Print greeting")
    call eng%add_command("library", "l(ist)",  EDGE_ACTION,  proc=act_list,  help="List books")
    call eng%add_command("library", "f(ind)",  EDGE_ACTION,  proc=act_find,  help="Find in titles", &
                         args=[arg_is_char("text")])
    call eng%add_command("library", "o(pen)",  EDGE_DO_GOTO, target="book", proc=act_open, &
                         help="Open book", args=[arg_is_int("id")])
    call eng%add_command("library", "q(uit)",  EDGE_QUIT,    help="Exit")

    ! Per-book state — context carries the id
    call eng%add_state("book", prompt="book> ")
    call eng%set_on_enter("book", enter_book)
    call eng%add_command("book", "r(ead)",  EDGE_ACTION, proc=act_read,  help="Show summary")
    call eng%add_command("book", "t(itle)", EDGE_ACTION, proc=act_title, help="Show title")
    call eng%add_command("book", "b(ack)",  EDGE_POP,    help="Back to library")
    call eng%add_command("book", "q(uit)",  EDGE_QUIT,   help="Exit")

    call eng%finalize("library")

    write(*,'(a)') "cmdgraph_f library demo — type `help` for commands"
    call eng%run()
end program library_demo
