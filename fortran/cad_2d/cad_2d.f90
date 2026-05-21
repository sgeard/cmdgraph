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
!     +--- point --- x[real] --- y[real] --->
!     |
!     +--- from  --- id[int]  --- dx[real] --- dy[real] --->
!
!  <style>
!     |
!     +--- colour --- n[integer] --->
!     |
!     +--- thickness --- t[real] --->
!
! Notes on the cmdgraph mapping:
!   - The point/style sub-graph is implemented via two states `line_mode`
!     and `p2_pending`. A `point` or `from` in line_mode is a do_goto that
!     pushes p2_pending carrying the first point's coords as context. A
!     `point` or `from` in p2_pending is a do_pop — it draws the line and
!     pops back to line_mode. `esc` in p2_pending is a plain pop (abort).
!   - Coordinate args use whitespace separation (`point 1.0 2.0`) rather
!     than the diagram's comma syntax — cmdgraph tokenises on whitespace.
!   - Two arities are modelled as two peer commands (`point`, `from`)
!     rather than overloading `point` — keeps each action's arg spec a
!     single-arity contract validated by the engine.
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

    ! Extract a real(8) from an engine-validated ARG_REAL node.
    ! The engine has already promoted int→real and rejected mismatches,
    ! so this is purely typed access — the class default arm is impossible.
    function as_real(node) result(v)
        class(dlist_node_data_t), intent(in) :: node
        real(8)                              :: v
        v = 0.0d0
        select type (node)
        type is (dlist_node_real)
            v = node%data
        end select
    end function as_real

    function as_int(node) result(v)
        class(dlist_node_data_t), intent(in) :: node
        integer                              :: v
        v = 0
        select type (node)
        type is (dlist_node_integer)
            v = node%data
        end select
    end function as_int

    ! Pull `x y` reals out of a 2-arg list.
    subroutine reals_xy(args, x, y)
        type(dlist_t), intent(in)             :: args
        real(8), intent(out)                  :: x, y
        class(dlist_node_data_t), allocatable :: n
        n = args%get(1); x = as_real(n)
        n = args%get(2); y = as_real(n)
    end subroutine reals_xy

    ! Encode an (x, y) pair as a do_goto context string.
    function ctx_of_xy(x, y) result(s)
        real(8), intent(in)                   :: x, y
        character(len=:), allocatable         :: s
        character(len=64)                     :: buf
        write(buf,'(es15.8,1x,es15.8)') x, y
        s = trim(adjustl(buf))
    end function ctx_of_xy

    ! Resolve a `from <id> <dx> <dy>` relative point to absolute coords.
    ! Returns ok=.false. and an error message if the id is out of range.
    subroutine resolve_from(id, dx, dy, x, y, ok, errmsg)
        integer, intent(in)                   :: id
        real(8), intent(in)                   :: dx, dy
        real(8), intent(out)                  :: x, y
        logical, intent(out)                  :: ok
        character(len=:), allocatable, intent(out) :: errmsg
        character(len=64)                     :: buf
        ok = .true.
        if (id < 1 .or. id > n_points) then
            write(buf,'("no point with id ",i0," (",i0," defined)")') id, n_points
            errmsg = trim(buf)
            ok = .false.
            x = 0.0d0; y = 0.0d0
            return
        end if
        x = points_x(id) + dx
        y = points_y(id) + dy
    end subroutine resolve_from

    ! Draw the line from the first point (in ctx) to (x2, y2), pop back.
    function draw_line(ctx, x2, y2) result(rv)
        character(len=*), intent(in)          :: ctx
        real(8), intent(in)                   :: x2, y2
        type(action_result_t)                 :: rv
        real(8)                               :: x1, y1
        integer                               :: iostat, id1, id2
        read(ctx, *, iostat=iostat) x1, y1
        if (iostat /= 0) then
            rv = action_error("internal: corrupt p2 context")
            return
        end if
        id1 = add_point(x1, y1)
        id2 = add_point(x2, y2)
        write(*,'(a,i0,a,i0,a,f0.3,a,f0.3,a,f0.3,a,f0.3,a,i0,a,f0.3)') &
            "line p", id1, " p", id2, ": (", x1, ", ", y1, ") -> (", x2, ", ", y2, &
            ")  colour=", cur_colour, " thickness=", cur_thickness
    end function draw_line

    ! ===== Point-entry actions =====

    ! line_mode: first point as direct (x, y) — push p2_pending with ctx.
    function act_p1_xy(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        real(8)                               :: x, y
        call reals_xy(args, x, y)
        rv = action_ok(ctx_of_xy(x, y))
    end function act_p1_xy

    ! line_mode: first point relative to point <id>.
    function act_p1_from(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        integer                               :: id
        real(8)                               :: dx, dy, x, y
        logical                               :: ok
        character(len=:), allocatable         :: errmsg
        n = args%get(1); id = as_int(n)
        n = args%get(2); dx = as_real(n)
        n = args%get(3); dy = as_real(n)
        call resolve_from(id, dx, dy, x, y, ok, errmsg)
        if (.not. ok) then
            rv = action_error(errmsg)
            return
        end if
        rv = action_ok(ctx_of_xy(x, y))
    end function act_p1_from

    ! p2_pending: second point as direct (x, y) — draw and pop.
    function act_p2_xy(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        real(8)                               :: x, y
        call reals_xy(args, x, y)
        rv = draw_line(ctx, x, y)
    end function act_p2_xy

    ! p2_pending: second point relative to point <id> — draw and pop.
    function act_p2_from(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        integer                               :: id
        real(8)                               :: dx, dy, x, y
        logical                               :: ok
        character(len=:), allocatable         :: errmsg
        n = args%get(1); id = as_int(n)
        n = args%get(2); dx = as_real(n)
        n = args%get(3); dy = as_real(n)
        call resolve_from(id, dx, dy, x, y, ok, errmsg)
        if (.not. ok) then
            rv = action_error(errmsg)
            return
        end if
        rv = draw_line(ctx, x, y)
    end function act_p2_from

    ! ===== Style actions =====

    function act_colour(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        n = args%get(1)
        cur_colour = as_int(n)
    end function act_colour

    function act_thickness(args, ctx) result(rv)
        type(dlist_t), intent(in)             :: args
        character(len=*), intent(in)          :: ctx
        type(action_result_t)                 :: rv
        class(dlist_node_data_t), allocatable :: n
        n = args%get(1)
        cur_thickness = as_real(n)
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
    call ui%add_command("line_mode", "p(oint)",     EDGE_DO_GOTO, target="p2_pending",  &
                       proc=act_p1_xy,   help="first point at (x, y)",                  &
                       args=[arg_is_real("x"), arg_is_real("y")])
    call ui%add_command("line_mode", "f(rom)",      EDGE_DO_GOTO, target="p2_pending",  &
                       proc=act_p1_from, help="first point as offset from point <id>",  &
                       args=[arg_is_int("id"), arg_is_real("dx"), arg_is_real("dy")])
    call ui%add_command("line_mode", "colour",      EDGE_ACTION, proc=act_colour,       &
                       help="set draw colour",    args=[arg_is_int("n")])
    call ui%add_command("line_mode", "t(hickness)", EDGE_ACTION, proc=act_thickness,    &
                       help="set line thickness", args=[arg_is_real("t")])
    call ui%add_command("line_mode", "b(ack)",      EDGE_POP,                           &
                       help="back to creator")
    call ui%add_command("line_mode", "q(uit)",      EDGE_QUIT,                          &
                       help="exit")

    call ui%add_state("p2_pending", prompt="p2> ")
    call ui%add_command("p2_pending", "p(oint)", EDGE_DO_POP, proc=act_p2_xy,           &
                       help="second point at (x, y)",                                   &
                       args=[arg_is_real("x"), arg_is_real("y")])
    call ui%add_command("p2_pending", "f(rom)",  EDGE_DO_POP, proc=act_p2_from,         &
                       help="second point as offset from point <id>",                   &
                       args=[arg_is_int("id"), arg_is_real("dx"), arg_is_real("dy")])
    call ui%add_command("p2_pending", "e(sc)",   EDGE_POP,                              &
                       help="abandon this line")
    call ui%add_command("p2_pending", "q(uit)",  EDGE_QUIT,                             &
                       help="exit")

    call ui%finalize("root")

    write(*,'(a)') "cmdgraph_f cad_2d demo — type `help` for commands at any prompt"
    call ui%run()
end program cad_2d
