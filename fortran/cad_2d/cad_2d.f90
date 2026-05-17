! A simple 2d CAD example of using the command processor.

! Just lines but obviously extensible
!
!                   +<----------------------+
!                   |                       |
!  create -+- line -+- <point> --- <point> -+
!                   |                       |
!                   +- <style> -------------+
!
!  <point>
!     |
!     +--- x[real],y[real] --------------------------->
!     |
!     +--- from --- [point_id] --- x[real],y[real] --->
!
!  <style>
!     |
!     +--- colour --- n[integer] --->
!     |
!     +--- thickness --- t[real] --->
!
! Notes on the cmdgraph mapping:
!   - The point/style sub-graph is implemented via two states `line_mode`
!     and `p2_pending`. A `point` (or `from`) in line_mode is a do_goto that
!     pushes p2_pending carrying the first point's coords as context. A
!     second `point` in p2_pending is a do_pop — it draws the line and pops
!     back to line_mode. `esc` in p2_pending is a plain pop (abort).
!   - Coordinate args use whitespace separation (`point 1.0 2.0`) rather
!     than the diagram's comma syntax — cmdgraph tokenises on whitespace.
!   - Point ids are 1-based and assigned on successful line creation
!     (both endpoints of every committed line are stored).
!   - Style commands are simple `action` edges in line_mode; the current
!     colour and thickness apply to subsequent lines.

module cad
    use cmdgraph
    use dlist
    implicit none

    integer, parameter           :: MAX_POINTS = 1024

    real(8), save                :: points_x(MAX_POINTS) = 0.0d0
    real(8), save                :: points_y(MAX_POINTS) = 0.0d0
    integer, save                :: n_points = 0

    integer, save                :: cur_colour    = 1
    real(8), save                :: cur_thickness = 1.0d0

contains

    function add_point(x, y) result(id)
        real(8), intent(in) :: x, y
        integer             :: id
        if (n_points >= MAX_POINTS) then
            id = 0
            return
        end if
        n_points = n_points + 1
        points_x(n_points) = x
        points_y(n_points) = y
        id = n_points
    end function add_point

    ! Pull a real from a dlist node, accepting either real or integer kind.
    function as_real(node, ok) result(v)
        class(dlist_node_data_t), intent(in) :: node
        logical, intent(out)                 :: ok
        real(8)                              :: v
        ok = .true.
        select type (node)
        type is (dlist_node_real)
            v = node%data
        type is (dlist_node_integer)
            v = real(node%data, kind=8)
        class default
            v  = 0.0d0
            ok = .false.
        end select
    end function as_real

    function as_int(node, ok) result(v)
        class(dlist_node_data_t), intent(in) :: node
        logical, intent(out)                 :: ok
        integer                              :: v
        ok = .true.
        select type (node)
        type is (dlist_node_integer)
            v = node%data
        class default
            v  = 0
            ok = .false.
        end select
    end function as_int

    ! Parse a <point> spec from args; either `x y` (2 args) or
    ! `from <id> <dx> <dy>` (4 args, first being the literal "from" character
    ! token). Returns absolute (x, y) and ok=.true. on success.
    subroutine read_point(args, x, y, ok)
        type(dlist_t), intent(in)             :: args
        real(8), intent(out)                  :: x, y
        logical, intent(out)                  :: ok
        class(dlist_node_data_t), allocatable :: n
        integer                               :: id
        real(8)                               :: dx, dy
        character(len=:), allocatable         :: kw
        logical                               :: ok2

        ok = .false.
        if (args%size() == 2) then
            n = args%get(1); x = as_real(n, ok2); if (.not. ok2) return
            n = args%get(2); y = as_real(n, ok2); if (.not. ok2) return
            ok = .true.
            return
        end if
        if (args%size() == 4) then
            n = args%get(1)
            select type (n)
            type is (dlist_node_char)
                kw = n%data
            class default
                return
            end select
            if (kw /= "from" .and. kw /= "f") return
            n = args%get(2); id = as_int(n, ok2); if (.not. ok2) return
            if (id < 1 .or. id > n_points) return
            n = args%get(3); dx = as_real(n, ok2); if (.not. ok2) return
            n = args%get(4); dy = as_real(n, ok2); if (.not. ok2) return
            x = points_x(id) + dx
            y = points_y(id) + dy
            ok = .true.
        end if
    end subroutine read_point

    ! p1 entry (line_mode): push p2_pending carrying "x y" as context.
    function act_p1(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        real(8)                               :: x, y
        logical                               :: ok
        character(len=64)                     :: buf

        call read_point(args, x, y, ok)
        if (.not. ok) then
            write(*,'(a)') "usage: point <x> <y>   |   point from <id> <dx> <dy>"
            return  ! unallocated rv%value → no transition
        end if
        write(buf,'(es15.8,1x,es15.8)') x, y
        rv%value = trim(adjustl(buf))
    end function act_p1

    ! p2 entry (p2_pending): draw the line from ctx + new point, then pop.
    function act_p2(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        real(8)                               :: x1, y1, x2, y2
        integer                               :: iostat, id1, id2
        logical                               :: ok

        read(ctx, *, iostat=iostat) x1, y1
        if (iostat /= 0) then
            rv = action_error()
            return
        end if
        call read_point(args, x2, y2, ok)
        if (.not. ok) then
            write(*,'(a)') "usage: point <x> <y>   |   point from <id> <dx> <dy>   |   esc"
            rv = action_error()   ! stay in p2_pending
            return
        end if
        id1 = add_point(x1, y1)
        id2 = add_point(x2, y2)
        write(*,'(a,i0,a,i0,a,f0.3,a,f0.3,a,f0.3,a,f0.3,a,i0,a,f0.3)') &
            "line p", id1, " p", id2, ": (", x1, ", ", y1, ") -> (", x2, ", ", y2, &
            ")  colour=", cur_colour, " thickness=", cur_thickness
    end function act_p2

    function act_colour(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        logical                               :: ok
        n = args%get(1)
        cur_colour = as_int(n, ok)   ! ok always .true. — engine validated
    end function act_colour

    function act_thickness(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        logical                               :: ok
        n = args%get(1)
        cur_thickness = as_real(n, ok)   ! ok always .true. — engine validated
    end function act_thickness

end module cad


program cad_2d
    use cmdgraph
    use cad
    implicit none

    type(engine_t) :: ui

    call ui%add_state("root", prompt="cad> ")
    call ui%add_command("root", "c(reate)", EDGE_GOTO, target="creator", help="create something")
    call ui%add_command("root", "q(uit)",   EDGE_QUIT,                   help="exit")

    call ui%add_state("creator", prompt="create> ")
    call ui%add_command("creator", "l(ine)", EDGE_GOTO, target="line_mode", help="draw lines")
    call ui%add_command("creator", "b(ack)", EDGE_POP,                      help="back")
    call ui%add_command("creator", "q(uit)", EDGE_QUIT,                     help="exit")

    call ui%add_state("line_mode", prompt="line> ")
    call ui%add_command("line_mode", "p(oint)",     EDGE_DO_GOTO, target="p2_pending", &
                       proc=act_p1,       help="first point: <x> <y> or from <id> <dx> <dy>")
    call ui%add_command("line_mode", "colour",      EDGE_ACTION, proc=act_colour,    &
                       help="set draw colour",    args=[arg_is_int("n")])
    call ui%add_command("line_mode", "t(hickness)", EDGE_ACTION, proc=act_thickness, &
                       help="set line thickness", args=[arg_is_real("t")])
    call ui%add_command("line_mode", "b(ack)",      EDGE_POP,                        &
                       help="back to creator")
    call ui%add_command("line_mode", "q(uit)",      EDGE_QUIT,                       &
                       help="exit")

    call ui%add_state("p2_pending", prompt="p2> ")
    call ui%add_command("p2_pending", "p(oint)", EDGE_DO_POP, proc=act_p2, &
                       help="second point: <x> <y> or from <id> <dx> <dy>")
    call ui%add_command("p2_pending", "e(sc)",   EDGE_POP,                 &
                       help="abandon this line")
    call ui%add_command("p2_pending", "q(uit)",  EDGE_QUIT,                &
                       help="exit")

    call ui%finalize("root")

    write(*,'(a)') "cmdgraph_f cad_2d demo — type `help` for commands at any prompt"
    call ui%run()
end program cad_2d
