// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Simon Geard
//
// cmdgraph C++ cad_2d demo — simple 2D line drawing REPL.
// Mirrors fortran/cad_2d/cad_2d.f90.
//
// State graph:
//   root → creator → line_mode ⇆ p2_pending
//
// `point` in line_mode is do_goto pushing p2_pending with "x y" as context;
// `point` in p2_pending is do_pop — draws the line then pops back. The two
// arities (direct coords vs `from id dx dy`) are modelled as two peer
// commands `point` and `from` rather than overloading `point`, so each
// command has a single-arity arg spec validated by the engine.

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

// Encode an (x, y) pair as a do_goto context string.
static std::string ctx_of_xy(double x, double y) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.8e %.8e", x, y);
    return buf;
}

// Resolve a `from id dx dy` relative point to absolute coords. Returns
// true on success; on failure, writes the diagnostic into errmsg.
static bool resolve_from(int id, double dx, double dy,
                         double& out_x, double& out_y, std::string& errmsg) {
    if (id < 1 || id > n_points) {
        errmsg = "no point with id " + std::to_string(id)
               + " (" + std::to_string(n_points) + " defined)";
        return false;
    }
    out_x = points_x[id-1] + dx;
    out_y = points_y[id-1] + dy;
    return true;
}

// Draw the line from the first point (in ctx) to (x2, y2), then pop.
static ActionResult draw_line(const std::string& ctx, double x2, double y2) {
    double x1, y1;
    std::istringstream ss(ctx);
    if (!(ss >> x1 >> y1)) return action_error("internal: corrupt p2 context");
    int id1 = add_point(x1, y1);
    int id2 = add_point(x2, y2);
    std::printf("line p%d p%d: (%.3f, %.3f) -> (%.3f, %.3f)  colour=%d thickness=%.3f\n",
        id1, id2, x1, y1, x2, y2, cur_colour, cur_thickness);
    return action_ok();
}

// ===== Point-entry actions =====

// line_mode: first point as direct (x, y) — push p2_pending with ctx.
static ActionResult act_p1_xy(const ArgList& args, const std::string&) {
    double x = arg_real(args[0]);
    double y = arg_real(args[1]);
    return action_ok(ctx_of_xy(x, y));
}

// line_mode: first point relative to point <id>.
static ActionResult act_p1_from(const ArgList& args, const std::string&) {
    int    id = arg_int (args[0]);
    double dx = arg_real(args[1]);
    double dy = arg_real(args[2]);
    double x, y;
    std::string errmsg;
    if (!resolve_from(id, dx, dy, x, y, errmsg)) return action_error(errmsg);
    return action_ok(ctx_of_xy(x, y));
}

// p2_pending: second point as direct (x, y) — draw and pop.
static ActionResult act_p2_xy(const ArgList& args, const std::string& ctx) {
    double x = arg_real(args[0]);
    double y = arg_real(args[1]);
    return draw_line(ctx, x, y);
}

// p2_pending: second point relative to point <id> — draw and pop.
static ActionResult act_p2_from(const ArgList& args, const std::string& ctx) {
    int    id = arg_int (args[0]);
    double dx = arg_real(args[1]);
    double dy = arg_real(args[2]);
    double x, y;
    std::string errmsg;
    if (!resolve_from(id, dx, dy, x, y, errmsg)) return action_error(errmsg);
    return draw_line(ctx, x, y);
}

// ===== Style actions =====

static ActionResult act_colour(const ArgList& args, const std::string&) {
    cur_colour = arg_int(args[0]);
    return action_ok();
}

static ActionResult act_thickness(const ArgList& args, const std::string&) {
    cur_thickness = arg_real(args[0]);
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
                   {.target="p2_pending", .proc=act_p1_xy,
                    .help="first point at (x, y)",
                    .args={arg_is_real("x"), arg_is_real("y")}});
    ui.add_command("line_mode", "f(rom)",  EdgeKind::DoGoto,
                   {.target="p2_pending", .proc=act_p1_from,
                    .help="first point as offset from point <id>",
                    .args={arg_is_int("id"), arg_is_real("dx"), arg_is_real("dy")}});
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
                   {.proc=act_p2_xy,
                    .help="second point at (x, y)",
                    .args={arg_is_real("x"), arg_is_real("y")}});
    ui.add_command("p2_pending", "f(rom)",  EdgeKind::DoPop,
                   {.proc=act_p2_from,
                    .help="second point as offset from point <id>",
                    .args={arg_is_int("id"), arg_is_real("dx"), arg_is_real("dy")}});
    ui.add_command("p2_pending", "e(sc)",   EdgeKind::Pop,  {.help="abandon this line"});
    ui.add_command("p2_pending", "q(uit)",  EdgeKind::Quit, {.help="exit"});

    ui.finalize("root");

    std::cout << "cmdgraph C++ cad_2d demo — type `help` for commands at any prompt\n";
    ui.run();
}
