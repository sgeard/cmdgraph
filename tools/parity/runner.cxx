// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Simon Geard
//
// Parity runner — C++.  Usage: runner_cpp <script> <result-file>
// Builds the canonical parity graph (see GRAPH.md), run_file the script with
// echo on, writes the normalised structured trailer to <result-file>.

#include "cmdgraph.hxx"

#include <fstream>
#include <iostream>
#include <string>

using namespace cmdgraph;

static ActionResult act_echo(const ArgList& a, const std::string&) {
    std::cout << "echo: " << arg_str(a[0]) << '\n';
    return action_ok();
}
static ActionResult act_add(const ArgList& a, const std::string&) {
    std::cout << "sum: " << (arg_int(a[0]) + arg_int(a[1])) << '\n';
    return action_ok();
}
static ActionResult act_save(const ArgList&, const std::string&) {
    std::cout << "save: ok\n";
    return action_ok();
}
static ActionResult act_send(const ArgList&, const std::string&) {
    std::cout << "send: ok\n";
    return action_ok();
}
static ActionResult act_scale(const ArgList&, const std::string&) {
    std::cout << "scale: ok\n";
    return action_ok();
}
static ActionResult act_open(const ArgList& a, const std::string&) {
    int id = arg_int(a[0]);
    if (id <= 0) return action_ok();
    return action_ok(std::to_string(id));
}
static ActionResult act_zero(const ArgList&, const std::string&) {
    return action_ok("0");
}
static ActionResult act_where(const ArgList&, const std::string& ctx) {
    std::cout << "where: ctx=" << ctx << '\n';
    return action_ok();
}
static ActionResult act_update(const ArgList& a, const std::string&) {
    std::cout << "update: " << arg_str(a[0]) << '\n';
    return action_ok();
}
static void enter_detail(const std::string& ctx) {
    std::cout << "entered detail ctx=" << ctx << '\n';
}

int main(int argc, char** argv) {
    if (argc < 3) {
        std::cerr << "usage: runner_cpp <script> <result-file>\n";
        return 2;
    }
    const std::string script  = argv[1];
    const std::string resfile = argv[2];

    Engine eng;
    eng.add_state("root", "root> ");
    eng.add_command("root", "e(cho)",  EdgeKind::Action,
                    {.proc=act_echo, .help="echo text", .args={arg_is_rest("text")}});
    eng.add_command("root", "ad(d)",   EdgeKind::Action,
                    {.proc=act_add, .help="add two ints",
                     .args={arg_is_int("x"), arg_is_int("y")}});
    eng.add_command("root", "s(ave)",  EdgeKind::Action, {.proc=act_save, .help="save"});
    eng.add_command("root", "s(end)",  EdgeKind::Action, {.proc=act_send, .help="send"});
    eng.add_command("root", "sc(ale)", EdgeKind::Action,
                    {.proc=act_scale, .help="scale", .args={arg_is_real("f")}});
    eng.add_command("root", "o(pen)",  EdgeKind::DoGoto,
                    {.target="detail", .proc=act_open, .help="open id",
                     .args={arg_is_int("id")}});
    eng.add_command("root", "z(ero)",  EdgeKind::DoGoto,
                    {.target="detail", .proc=act_zero, .help="zero-ctx do_goto"});
    eng.add_command("root", "g(o)",    EdgeKind::Goto,  {.target="detail", .help="go"});
    eng.add_command("root", "q(uit)",  EdgeKind::Quit,  {.help="quit"});

    eng.add_state("detail", "detail> ");
    eng.set_on_enter("detail", enter_detail);
    eng.add_command("detail", "w(here)",  EdgeKind::Action,
                    {.proc=act_where, .help="show context"});
    eng.add_command("detail", "u(pdate)", EdgeKind::DoPop,
                    {.proc=act_update, .help="update note", .args={arg_is_rest("note")}});
    eng.add_command("detail", "b(ack)",   EdgeKind::Pop,  {.help="back"});
    eng.add_command("detail", "q(uit)",   EdgeKind::Quit, {.help="quit"});

    eng.finalize("root");

    RC  st   = RC::Ok;
    int line = 0;
    bool ok  = eng.run_file(script, true, &st, &line);

    std::string rc;
    if (!ok && line == 0) {
        rc = "OPEN_FAIL";
    } else if (ok) {
        rc = "OK";
    } else {
        switch (st) {
            case RC::Unknown:      rc = "UNKNOWN";      break;
            case RC::Ambiguous:    rc = "AMBIGUOUS";    break;
            case RC::Transitioned: rc = "TRANSITIONED"; break;
            case RC::Exited:       rc = "EXITED";       break;
            case RC::Error:        rc = "ERROR";        break;
            default:               rc = "OK";           break;
        }
    }

    std::ofstream f(resfile);
    f << "ok=" << (ok ? 1 : 0) << '\n';
    f << "rc=" << rc << '\n';
    f << "line=" << line << '\n';
    f << "state=" << eng.current_state() << '\n';
    f << "last_message=" << eng.last_message << '\n';
    f << "last_error=" << eng.last_error << '\n';
    return 0;
}
