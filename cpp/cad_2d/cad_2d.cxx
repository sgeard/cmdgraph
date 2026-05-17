// cmdgraph C++ cad_2d demo — simple 2D line drawing REPL.
// Mirrors fortran/cad_2d/cad_2d.f90.
//
// State graph:
//   root → creator → line_mode ⇆ p2_pending
//
// `point` in line_mode is do_goto pushing p2_pending with "x y" as context.
// `point` in p2_pending is do_pop — draws the line then pops back.
// `colour` and `thickness` use arg specs; `point` keeps manual validation
// since it accepts two distinct arities (x y | from id dx dy).

#include "cmdgraph.hxx"

#include <cstdio>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

using namespace cmdgraph;

static constexpr int MAX_POINTS = 1024;

static double points_x[MAX_POINTS];
static double points_y[MAX_POINTS];
static int    n_points     = 0;
static int    cur_colour   = 1;
static double cur_thickness = 1.0;

static int add_point(double x, double y) {
    if (n_points >= MAX_POINTS) return 0;
    points_x[n_points] = x;
    points_y[n_points] = y;
    return ++n_points;
}

// Extract a real from an ArgValue accepting both int and double.
static bool as_real(const ArgValue& v, double& out) {
    if (std::holds_alternative<double>(v))  { out = std::get<double>(v); return true; }
    if (std::holds_alternative<int>(v))     { out = std::get<int>(v);    return true; }
    return false;
}

// Parse a point from args: either `x y` (2 args) or `from id dx dy` (4 args).
// Returns absolute (x,y) in out_x/out_y and true on success.
static bool read_point(const ArgList& args, double& out_x, double& out_y) {
    if (args.size() == 2) {
        return as_real(args[0], out_x) && as_real(args[1], out_y);
    }
    if (args.size() == 4) {
        if (!std::holds_alternative<std::string>(args[0])) return false;
        const auto& kw = std::get<std::string>(args[0]);
        if (kw != "from" && kw != "f") return false;
        if (!std::holds_alternative<int>(args[1])) return false;
        int id = std::get<int>(args[1]);
        if (id < 1 || id > n_points) return false;
        double dx, dy;
        if (!as_real(args[2], dx) || !as_real(args[3], dy)) return false;
        out_x = points_x[id-1] + dx;
        out_y = points_y[id-1] + dy;
        return true;
    }
    return false;
}

// p1 (line_mode): push p2_pending carrying "x y" as context.
static ActionResult act_p1(const ArgList& args, const std::string&) {
    double x, y;
    if (!read_point(args, x, y)) {
        std::cout << "usage: point <x> <y>   |   point from <id> <dx> <dy>\n";
        return action_error();
    }
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.8e %.8e", x, y);
    return action_ok(buf);
}

// p2 (p2_pending): draw the line from ctx + new point, then pop.
static ActionResult act_p2(const ArgList& args, const std::string& ctx) {
    double x1, y1;
    std::istringstream ss(ctx);
    if (!(ss >> x1 >> y1)) return action_error();

    double x2, y2;
    if (!read_point(args, x2, y2)) {
        std::cout << "usage: point <x> <y>   |   point from <id> <dx> <dy>   |   esc\n";
        return action_error();
    }
    int id1 = add_point(x1, y1);
    int id2 = add_point(x2, y2);
    std::printf("line p%d p%d: (%.3f, %.3f) -> (%.3f, %.3f)  colour=%d thickness=%.3f\n",
        id1, id2, x1, y1, x2, y2, cur_colour, cur_thickness);
    return action_ok();
}

static ActionResult act_colour(const ArgList& args, const std::string&) {
    cur_colour = arg_int(args[0]);   // engine validated ARG_INT
    return action_ok();
}

static ActionResult act_thickness(const ArgList& args, const std::string&) {
    cur_thickness = arg_real(args[0]);  // engine validated ARG_REAL
    return action_ok();
}

int main() {
    Engine ui;

    ui.add_state("root",    "cad> ");
    ui.add_command("root", "c(reate)", EdgeKind::Goto,
                   {.target="creator", .help="create something"});
    ui.add_command("root", "q(uit)",   EdgeKind::Quit, {.help="exit"});

    ui.add_state("creator", "create> ");
    ui.add_command("creator", "l(ine)", EdgeKind::Goto,
                   {.target="line_mode", .help="draw lines"});
    ui.add_command("creator", "b(ack)", EdgeKind::Pop,  {.help="back"});
    ui.add_command("creator", "q(uit)", EdgeKind::Quit, {.help="exit"});

    ui.add_state("line_mode", "line> ");
    ui.add_command("line_mode", "p(oint)", EdgeKind::DoGoto,
                   {.target="p2_pending", .proc=act_p1,
                    .help="first point: <x> <y> or from <id> <dx> <dy>"});
    ui.add_command("line_mode", "colour",      EdgeKind::Action,
                   {.proc=act_colour,    .help="set draw colour",
                    .args={arg_is_int("n")}});
    ui.add_command("line_mode", "t(hickness)", EdgeKind::Action,
                   {.proc=act_thickness, .help="set line thickness",
                    .args={arg_is_real("t")}});
    ui.add_command("line_mode", "b(ack)",      EdgeKind::Pop,  {.help="back to creator"});
    ui.add_command("line_mode", "q(uit)",      EdgeKind::Quit, {.help="exit"});

    ui.add_state("p2_pending", "p2> ");
    ui.add_command("p2_pending", "p(oint)", EdgeKind::DoPop,
                   {.proc=act_p2,
                    .help="second point: <x> <y> or from <id> <dx> <dy>"});
    ui.add_command("p2_pending", "e(sc)",   EdgeKind::Pop,  {.help="abandon this line"});
    ui.add_command("p2_pending", "q(uit)",  EdgeKind::Quit, {.help="exit"});

    ui.finalize("root");

    std::cout << "cmdgraph C++ cad_2d demo — type `help` for commands at any prompt\n";
    ui.run();
}
