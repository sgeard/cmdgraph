// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Simon Geard
//
// Unit tests for cmdgraph C++. Mirrors fortran/test/utest_cmdgraph.f90.

#include "cmdgraph.hxx"

#include <iostream>
#include <sstream>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

using namespace cmdgraph;

// ── Test harness ──────────────────────────────────────────────────────────────

static int g_pass = 0, g_fail = 0;

static void check_int(const std::string& label, int got, int expected) {
    if (got == expected) {
        std::cout << "PASS: " << label << '\n';
        ++g_pass;
    } else {
        std::cout << "FAIL: " << label
                  << " (got " << got << ", expected " << expected << ")\n";
        ++g_fail;
    }
}

static void check_str(const std::string& label,
                       const std::string& got, const std::string& expected) {
    if (got == expected) {
        std::cout << "PASS: " << label << '\n';
        ++g_pass;
    } else {
        std::cout << "FAIL: " << label
                  << " (got '" << got << "', expected '" << expected << "')\n";
        ++g_fail;
    }
}

static void check_bool(const std::string& label, bool got, bool expected) {
    if (got == expected) {
        std::cout << "PASS: " << label << '\n';
        ++g_pass;
    } else {
        std::cout << "FAIL: " << label
                  << " (got " << (got?"true":"false")
                  << ", expected " << (expected?"true":"false") << ")\n";
        ++g_fail;
    }
}

// Cast RC to int for check_int convenience
static int rc(RC r) { return static_cast<int>(r); }
static int RC_OK           = rc(RC::Ok);
static int RC_UNKNOWN      = rc(RC::Unknown);
static int RC_AMBIGUOUS    = rc(RC::Ambiguous);
static int RC_TRANSITIONED = rc(RC::Transitioned);
static int RC_EXITED       = rc(RC::Exited);
static int RC_ERROR        = rc(RC::Error);

// ── Probe infrastructure ──────────────────────────────────────────────────────

static int  g_outer_count   = 0;
static int  g_last_select   = -1;
static int  g_commit_count  = 0;
static double g_last_real   = 0.0;
static std::string g_last_word;
static std::string g_enter_detail_ctx;
static int  g_rest_nargs    = -1;
static int  g_rest_int      = -1;
static std::string g_rest_str;

static ActionResult act_outer(const ArgList&, const std::string&) {
    ++g_outer_count; return action_ok();
}

static ActionResult act_select(const ArgList& args, const std::string&) {
    if (!args.empty()) g_last_select = arg_int(args[0]);
    char buf[16];
    std::snprintf(buf, sizeof(buf), "%d", g_last_select);
    return action_ok(buf);   // triggers do_goto
}

static ActionResult act_fail(const ArgList&, const std::string&) {
    return action_ok();  // empty value → no transition
}

static ActionResult act_real(const ArgList& args, const std::string&) {
    if (!args.empty()) g_last_real = arg_real(args[0]);
    return action_ok();
}

static ActionResult act_word(const ArgList& args, const std::string&) {
    if (!args.empty()) g_last_word = arg_str(args[0]);
    return action_ok();
}

static ActionResult act_commit(const ArgList&, const std::string&) {
    ++g_commit_count; return action_ok();
}

static void enter_detail(const std::string& ctx) {
    g_enter_detail_ctx = ctx;
}

static ActionResult act_rest(const ArgList& args, const std::string&) {
    g_rest_nargs = (int)args.size();
    if (!args.empty() && std::holds_alternative<int>(args[0]))
        g_rest_int = arg_int(args[0]);
    if (!args.empty() && std::holds_alternative<std::string>(args.back()))
        g_rest_str = arg_str(args.back());
    return action_ok();
}

// ── Build the reference engine ────────────────────────────────────────────────

static Engine build_eng(std::ostream* out = nullptr, std::ostream* err = nullptr) {
    Engine eng;
    if (out) eng.set_io(nullptr, out, err ? err : out);
    else     eng.set_io(nullptr, out, err);

    eng.add_state("home",   "home> ");
    eng.add_command("home", "a(ction)", EdgeKind::Action,
                    {.proc=act_outer,  .help="bump counter"});
    eng.add_command("home", "s(elect)", EdgeKind::DoGoto,
                    {.target="detail", .proc=act_select,
                     .help="Select <id>", .args={arg_is_int("id")}});
    eng.add_command("home", "g(o)",     EdgeKind::Goto,
                    {.target="detail", .help="Goto detail"});
    eng.add_command("home", "f(ail)",   EdgeKind::DoGoto,
                    {.target="detail", .proc=act_fail, .help="always fails"});
    eng.add_command("home", "r(eal)",   EdgeKind::Action,
                    {.proc=act_real, .help="capture real",
                     .args={arg_is_real("v")}});
    eng.add_command("home", "w(ord)",   EdgeKind::Action,
                    {.proc=act_word, .help="capture word",
                     .args={arg_is_char("w")}});
    eng.add_command("home", "q(uit)",   EdgeKind::Quit, {.help="quit"});

    eng.add_state("detail", "detail> ");
    eng.set_on_enter("detail", enter_detail);
    eng.add_command("detail", "i(nner)",  EdgeKind::Action,
                    {.proc=act_outer, .help="inner action"});
    eng.add_command("detail", "c(ommit)", EdgeKind::DoPop,
                    {.proc=act_commit, .help="commit and pop"});
    eng.add_command("detail", "b(ack)",   EdgeKind::Pop, {.help="back"});
    eng.add_command("detail", "q(uit)",   EdgeKind::Quit, {.help="quit"});

    eng.finalize("home");
    if (out) eng.set_io(nullptr, out, err ? err : out);
    return eng;
}

// ── Test functions ────────────────────────────────────────────────────────────

static void test_initial_state() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss);
    check_str("initial state", eng.current_state(), "home");
    check_bool("is_running at start", eng.is_running(), true);
    check_str("initial context empty", eng.current_context(), "");
}

static void test_action_edge() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss);
    g_outer_count = 0;
    check_int("action edge rc", rc(eng.dispatch("action")), RC_OK);
    check_int("action edge invokes proc", g_outer_count, 1);
    check_str("action edge stays", eng.current_state(), "home");
}

static void test_prefix_matching() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss);
    check_int("full match",     rc(eng.dispatch("action")),  RC_OK);
    check_int("min prefix",     rc(eng.dispatch("a")),       RC_OK);
    check_int("mid prefix",     rc(eng.dispatch("ac")),      RC_OK);
}

static void test_empty_line() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss);
    check_int("empty line", rc(eng.dispatch("")), RC_OK);
    check_str("state unchanged after empty", eng.current_state(), "home");
}

static void test_unknown() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss, &oss);
    check_int("unknown rc", rc(eng.dispatch("zzz")), RC_UNKNOWN);
}

static void test_ambiguous_engine() {
    std::ostringstream oss;
    Engine eng;
    eng.set_io(nullptr, &oss, &oss);
    eng.add_state("s", "s> ");
    eng.add_command("s", "s(ave)",    EdgeKind::Action, {.proc=act_outer});
    eng.add_command("s", "s(elect)",  EdgeKind::Action, {.proc=act_outer});
    eng.add_command("s", "q(uit)",    EdgeKind::Quit);
    eng.finalize("s");
    check_int("ambiguous rc", rc(eng.dispatch("s")), RC_AMBIGUOUS);
}

static void test_goto() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss);
    check_int("goto rc", rc(eng.dispatch("go")), RC_TRANSITIONED);
    check_str("goto pushes state", eng.current_state(), "detail");
    check_str("goto empty context", eng.current_context(), "");
    auto path = eng.state_path();
    check_int("path depth after goto", (int)path.size(), 2);
    check_str("path[0] after goto", path[0], "home");
    check_str("path[1] after goto", path[1], "detail");
}

static void test_do_goto_success() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss);
    g_last_select = -1;
    g_enter_detail_ctx = "";
    check_int("do_goto success rc", rc(eng.dispatch("select 42")), RC_TRANSITIONED);
    check_str("do_goto pushes state", eng.current_state(), "detail");
    check_int("select captures arg", g_last_select, 42);
    check_str("context set by do_goto", eng.current_context(), "42");
    check_str("on_enter saw context", g_enter_detail_ctx, "42");
}

static void test_do_goto_fail() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss);
    check_int("do_goto fail rc", rc(eng.dispatch("fail")), RC_OK);
    check_str("do_goto fail stays", eng.current_state(), "home");
}

static void test_pop() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss);
    (void)eng.dispatch("go");  // push to detail; RC not under test here
    check_int("pop rc", rc(eng.dispatch("back")), RC_TRANSITIONED);
    check_str("pop restores state", eng.current_state(), "home");
}

static void test_pop_to_empty() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss, &oss);
    // pop at root exits
    check_int("pop at root rc", rc(eng.dispatch("go")), RC_TRANSITIONED);
    check_int("back", rc(eng.dispatch("back")), RC_TRANSITIONED);
    check_bool("still running after back to home", eng.is_running(), true);
}

static void test_do_pop() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss);
    g_commit_count = 0;
    (void)eng.dispatch("go");  // push to detail; RC not under test here
    check_int("do_pop rc", rc(eng.dispatch("commit")), RC_TRANSITIONED);
    check_int("do_pop invokes proc", g_commit_count, 1);
    check_str("do_pop pops state", eng.current_state(), "home");
}

static void test_quit() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss);
    check_int("quit rc", rc(eng.dispatch("quit")), RC_EXITED);
    check_bool("not running after quit", eng.is_running(), false);
}

static void test_arg_int() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss, &oss);
    g_last_select = -1;
    check_int("int arg dispatch", rc(eng.dispatch("select 7")), RC_TRANSITIONED);
    check_int("int arg captured", g_last_select, 7);
    eng.reset();
    check_int("int arg wrong type", rc(eng.dispatch("select 3.14")), RC_ERROR);
    eng.reset();
    check_int("int arg missing", rc(eng.dispatch("select")), RC_ERROR);
    eng.reset();
    check_int("int arg too many", rc(eng.dispatch("select 1 2")), RC_ERROR);
}

static void test_arg_real() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss, &oss);
    g_last_real = 0.0;
    check_int("real arg dispatch", rc(eng.dispatch("real 3.14")), RC_OK);
    check_bool("real arg captured", g_last_real > 3.13 && g_last_real < 3.15, true);
    // Int → real promotion: an integer literal in a real slot is accepted and
    // the action receives a double-valued variant (parity with Tcl/Fortran).
    g_last_real = 0.0;
    check_int("real arg accepts int token (promoted)",
              rc(eng.dispatch("real 2")), RC_OK);
    check_bool("real arg int-promoted value",
               g_last_real > 1.99 && g_last_real < 2.01, true);
    // Fortran-style exponents
    g_last_real = 0.0;
    check_int("real d-exponent dispatch",  rc(eng.dispatch("real 1.5d2")), RC_OK);
    check_bool("real d-exponent value",    g_last_real > 149.9 && g_last_real < 150.1, true);
    g_last_real = 0.0;
    check_int("real D-exponent dispatch",  rc(eng.dispatch("real 2.0D-1")), RC_OK);
    check_bool("real D-exponent value",    g_last_real > 0.19 && g_last_real < 0.21, true);
}

static void test_arg_char() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss, &oss);
    g_last_word = "";
    check_int("char arg dispatch", rc(eng.dispatch("word hello")), RC_OK);
    check_str("char arg captured", g_last_word, "hello");
    check_int("char quoted", rc(eng.dispatch("word \"hello world\"")), RC_OK);
    check_str("quoted captures spaces", g_last_word, "hello world");
}

static void test_includes() {
    std::ostringstream oss;
    Engine eng;
    eng.set_io(nullptr, &oss, &oss);
    int shared_count = 0;
    auto act_shared = [&](const ArgList&, const std::string&) -> ActionResult {
        ++shared_count; return action_ok();
    };
    eng.add_state("shared");  // abstract
    eng.add_command("shared", "x(tra)", EdgeKind::Action, {.proc=act_shared, .help="shared"});
    eng.add_state("a", "a> ");
    eng.add_include("a", "shared");
    eng.add_command("a", "q(uit)", EdgeKind::Quit);
    eng.add_state("b", "b> ");
    eng.add_include("b", "shared");
    eng.add_command("b", "q(uit)", EdgeKind::Quit);
    eng.finalize("a");

    shared_count = 0;
    check_int("include: shared cmd in a", rc(eng.dispatch("xtra")), RC_OK);
    check_int("include: proc invoked", shared_count, 1);
}

static void test_reset() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss);
    (void)eng.dispatch("go");  // push to detail; RC not under test here
    check_str("in detail before reset", eng.current_state(), "detail");
    eng.reset();
    check_str("reset restores initial", eng.current_state(), "home");
    check_bool("is_running after reset", eng.is_running(), true);
    check_int("dispatch after reset", rc(eng.dispatch("action")), RC_OK);
}

static void test_run_file() {
    // Write a temporary script
    const std::string path = "/tmp/cmdgraph_test_script.txt";
    {
        std::ofstream f(path);
        f << "action\n";
        f << "action\n";
    }
    std::ostringstream oss;
    Engine eng = build_eng(&oss, &oss);
    g_outer_count = 0;
    RC stat;
    int line;
    bool ok = eng.run_file(path, false, &stat, &line);
    check_bool("run_file ok", ok, true);
    check_int("run_file ran 2 lines", g_outer_count, 2);

    // Error on bad command
    {
        std::ofstream f(path);
        f << "action\n";
        f << "zzz\n";
        f << "action\n";
    }
    eng.reset();
    g_outer_count = 0;
    ok = eng.run_file(path, false, &stat, &line);
    check_bool("run_file stops on error", !ok, true);
    check_int("run_file error line", line, 2);
    check_int("run_file ran 1 before error", g_outer_count, 1);
}

static void test_io_suppress() {
    // Suppress both channels; verify the engine still populates
    // last_message / last_error (the in-memory mirrors of the channels).
    // Under the parity contract, "unknown" is an info-channel event so it
    // populates last_message; last_error is reserved for genuine error events.
    // (set_io with nullptr is a no-op — pass throwaway streams instead.)
    std::ostringstream sink_out, sink_err;
    Engine eng;
    eng.set_io(nullptr, &sink_out, &sink_err);
    eng.add_state("s", "s> ");
    eng.add_command("s", "q(uit)", EdgeKind::Quit);
    eng.finalize("s");
    (void)eng.dispatch("zzz");  // unknown → emit_info_ → last_message
    check_bool("suppress: last_message set",  !eng.last_message.empty(), true);
    check_str ("suppress: last_message text",  eng.last_message, "unknown: zzz");
    check_bool("suppress: last_error empty",   eng.last_error.empty(),   true);
}

static void test_introspection() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss);
    auto cmds = eng.available_commands();
    check_bool("available_commands non-empty", !cmds.empty(), true);

    // Find "s(elect)" in the list
    bool found = false;
    for (const auto& c : cmds)
        if (c.spec == "s(elect)") { found = true; break; }
    check_bool("available_commands has s(elect)", found, true);

    // state_path at home
    auto path = eng.state_path();
    check_int("state_path depth at home", (int)path.size(), 1);
    check_str("state_path[0] is home", path[0], "home");

    // After goto: 2 states in path
    (void)eng.dispatch("go");  // navigating for introspection test; RC not under test
    path = eng.state_path();
    check_int("state_path depth after goto", (int)path.size(), 2);
}

static void test_help() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss, &oss);
    check_int("help rc", rc(eng.dispatch("help")), RC_OK);
    const std::string& msg = eng.last_message;
    check_bool("help contains s(elect)", msg.find("s(elect)") != std::string::npos, true);
    check_bool("help contains <id:int>",  msg.find("<id:int>") != std::string::npos, true);
    check_bool("help contains r(eal)",    msg.find("r(eal)")   != std::string::npos, true);
    check_bool("help contains <v:real>",  msg.find("<v:real>") != std::string::npos, true);
}

static void test_rest_of_line() {
    std::ostringstream oss;
    Engine eng;
    eng.set_io(nullptr, &oss, &oss);
    eng.add_state("s", "s> ");
    eng.add_command("s", "r(est)", EdgeKind::Action,
                    {.proc=act_rest, .help="rest arg",
                     .args={arg_is_int("n"), arg_is_rest("msg")}});
    eng.add_command("s", "q(uit)", EdgeKind::Quit);
    eng.finalize("s");

    g_rest_nargs = -1;
    check_int("rest dispatch rc", rc(eng.dispatch("rest 3 hello world")), RC_OK);
    check_int("rest nargs", g_rest_nargs, 2);
    check_int("rest int captured", g_rest_int, 3);
    check_str("rest str captured", g_rest_str, "hello world");

    // Rest only (no leading int)
    Engine eng2;
    eng2.set_io(nullptr, &oss, &oss);
    eng2.add_state("s", "s> ");
    eng2.add_command("s", "r(est)", EdgeKind::Action,
                     {.proc=act_rest, .help="rest", .args={arg_is_rest("msg")}});
    eng2.add_command("s", "q", EdgeKind::Quit);
    eng2.finalize("s");
    g_rest_nargs = -1;
    check_int("rest-only dispatch", rc(eng2.dispatch("rest hello world")), RC_OK);
    check_int("rest-only nargs", g_rest_nargs, 1);
    check_str("rest-only str", g_rest_str, "hello world");

    // Empty required rest → "missing required argument <name>" (parity with
    // Tcl/Fortran — both refuse to invoke the action with an empty rest slot).
    g_rest_nargs = -1;
    check_int("empty required rest rc",
              rc(eng2.dispatch("rest")), RC_ERROR);
    check_int("empty required rest action not invoked", g_rest_nargs, -1);
    check_str("empty required rest last_error", eng2.last_error,
              "missing required argument <msg>");

    // Optional rest is allowed to be empty; the action is invoked with zero args.
    Engine eng3;
    eng3.set_io(nullptr, &oss, &oss);
    eng3.add_state("s", "s> ");
    eng3.add_command("s", "r(est)", EdgeKind::Action,
                     {.proc=act_rest, .help="rest",
                      .args={arg_is_rest("msg", true)}});
    eng3.add_command("s", "q", EdgeKind::Quit);
    eng3.finalize("s");
    g_rest_nargs = -1;
    check_int("empty optional rest rc",
              rc(eng3.dispatch("rest")), RC_OK);
    check_int("empty optional rest nargs (no rest pushed)",
              g_rest_nargs, 0);
}

static void test_array_specs() {
    std::ostringstream oss;
    Engine eng;
    eng.set_io(nullptr, &oss, &oss);

    std::vector<int>    pts_int;
    std::vector<double> pts_real;

    auto act_int3 = [&](const ArgList& args, const std::string&) -> ActionResult {
        pts_int.clear();
        for (const auto& v : args) pts_int.push_back(arg_int(v));
        return action_ok();
    };
    auto act_pt = [&](const ArgList& args, const std::string&) -> ActionResult {
        pts_real.clear();
        for (const auto& v : args) pts_real.push_back(arg_real(v));
        return action_ok();
    };

    auto int3_args = arg_int_n("n", 3);
    auto pt_args   = arg_real_n("pt", 2);

    eng.add_state("s", "s> ");
    eng.add_command("s", "i(nt3)",  EdgeKind::Action, {.proc=act_int3, .help="3 ints",  .args=int3_args});
    eng.add_command("s", "p(oint)", EdgeKind::Action, {.proc=act_pt,   .help="2 reals", .args=pt_args});
    eng.add_command("s", "q",       EdgeKind::Quit);
    eng.finalize("s");

    check_int("int3 dispatch", rc(eng.dispatch("int3 1 2 3")), RC_OK);
    check_int("int3 arg 0", pts_int.size() >= 1 ? pts_int[0] : -1, 1);
    check_int("int3 arg 1", pts_int.size() >= 2 ? pts_int[1] : -1, 2);
    check_int("int3 arg 2", pts_int.size() >= 3 ? pts_int[2] : -1, 3);

    check_int("pt dispatch", rc(eng.dispatch("point 1.5 2.5")), RC_OK);
    check_bool("pt arg 0", pts_real.size() >= 1 && pts_real[0] > 1.4, true);
    check_bool("pt arg 1", pts_real.size() >= 2 && pts_real[1] > 2.4, true);

    check_int("int3 wrong count", rc(eng.dispatch("int3 1 2")), RC_ERROR);

    // Help shows <n:int> <n:int> <n:int>
    (void)eng.dispatch("help");  // testing last_message content, not RC
    const std::string& msg = eng.last_message;
    check_bool("array help: 2 real slots", msg.find("p(oint) <pt:real> <pt:real>") != std::string::npos, true);
    check_bool("array help: 3 int slots",  msg.find("i(nt3) <n:int> <n:int> <n:int>") != std::string::npos, true);
}

static ActionResult act_fail_msg    (const ArgList&, const std::string&) {
    return action_error("something went wrong");
}
static ActionResult act_fail_silent (const ArgList&, const std::string&) {
    return action_error();
}
static ActionResult act_do_fail_msg (const ArgList&, const std::string&) {
    return action_error("do_goto failed");
}

static void test_action_errmsg() {
    std::ostringstream oss;
    Engine e;
    e.set_io(nullptr, &oss, &oss);
    e.add_state("home", "h> ");
    e.add_state("dest", "d> ");
    e.add_command("home", "f(ail)",   EdgeKind::Action,  {.proc=act_fail_msg,    .help="fails with message"});
    e.add_command("home", "s(ilent)", EdgeKind::Action,  {.proc=act_fail_silent, .help="fails without message"});
    e.add_command("home", "d(o)",     EdgeKind::DoGoto,
                  {.target="dest", .proc=act_do_fail_msg, .help="do_goto fails"});
    e.add_command("dest", "b(ack)",   EdgeKind::Pop, {.help="back"});
    e.finalize("home");

    check_int("errmsg: action RC_ERROR",    rc(e.dispatch("fail")),   RC_ERROR);
    check_str("errmsg: action last_error",  e.last_error,             "something went wrong");

    e.reset();
    check_int("errmsg: silent RC_ERROR",    rc(e.dispatch("silent")), RC_ERROR);
    check_str("errmsg: silent last_error",  e.last_error,             "");

    check_int("errmsg: do_goto RC_ERROR",   rc(e.dispatch("do")),     RC_ERROR);
    check_str("errmsg: do_goto last_error", e.last_error,             "do_goto failed");
}

static void test_constructors() {
    ActionResult rv;

    rv = action_ok();
    check_bool("action_ok() errored=false", !rv.errored, true);
    check_bool("action_ok() value nullopt", !rv.value.has_value(), true);

    rv = action_ok("my-ctx");
    check_bool("action_ok(ctx) errored=false", !rv.errored, true);
    check_str ("action_ok(ctx) value",         *rv.value,  "my-ctx");

    rv = action_error();
    check_bool("action_error() errored=true",    rv.errored, true);
    check_bool("action_error() errmsg nullopt", !rv.errmsg.has_value(), true);

    rv = action_error("oops");
    check_bool("action_error(msg) errored=true", rv.errored, true);
    check_str ("action_error(msg) errmsg",       *rv.errmsg, "oops");
}

static void test_builder_errors() {
    // Each of these should throw
    auto throws = [](auto fn) -> bool {
        try { fn(); return false; }
        catch (const std::runtime_error&) { return true; }
    };

    check_bool("duplicate state throws",
        throws([]{ Engine e; e.add_state("a","a> "); e.add_state("a","a> "); }), true);

    check_bool("add_command unknown state throws",
        throws([]{
            Engine e; e.add_state("a","a> ");
            e.add_command("b", "x", EdgeKind::Action);
        }), true);

    check_bool("finalize unknown initial throws",
        throws([]{
            Engine e; e.add_state("a","a> ");
            e.finalize("b");
        }), true);

    check_bool("goto unknown target throws at finalize",
        throws([]{
            Engine e;
            e.add_state("a","a> ");
            e.add_command("a", "g", EdgeKind::Goto, {.target="b"});
            e.finalize("a");
        }), true);

    check_bool("cycle throws at finalize",
        throws([]{
            Engine e;
            e.add_state("a","a> ");
            e.add_state("b","b> ");
            e.add_command("a","g",EdgeKind::Goto,{.target="b"});
            e.add_command("b","h",EdgeKind::Goto,{.target="a"});
            e.finalize("a");
        }), true);

    check_bool("ARG_REST not last throws",
        throws([]{
            Engine e; e.add_state("a","a> ");
            e.add_command("a","x",EdgeKind::Action,
                {.args={arg_is_rest("r"), arg_is_int("n")}});
        }), true);

    // Construction-time edge validation — canonical wording must be byte-
    // identical to Fortran die_missing and Tcl parse_edge (parity contract):
    //   cmdgraph: <kind> edge '<spec>' missing required <proc|target>
    auto throw_msg = [](auto fn) -> std::string {
        try { fn(); return {}; }
        catch (const std::runtime_error& e) { return e.what(); }
    };

    check_str("action edge missing proc msg",
        throw_msg([]{
            Engine e; e.add_state("r","r> ");
            e.add_command("r","a(ct)",EdgeKind::Action);
        }),
        "cmdgraph: action edge 'a(ct)' missing required proc");

    check_str("goto edge missing target msg",
        throw_msg([]{
            Engine e; e.add_state("r","r> ");
            e.add_command("r","g(o)",EdgeKind::Goto);
        }),
        "cmdgraph: goto edge 'g(o)' missing required target");

    check_str("do_goto edge missing target msg",
        throw_msg([]{
            Engine e; e.add_state("r","r> ");
            e.add_command("r","t(ry)",EdgeKind::DoGoto,{.proc=act_outer});
        }),
        "cmdgraph: do_goto edge 't(ry)' missing required target");

    check_str("do_goto edge missing proc msg",
        throw_msg([]{
            Engine e; e.add_state("r","r> "); e.add_state("d","d> ");
            e.add_command("r","t(ry)",EdgeKind::DoGoto,{.target="d"});
        }),
        "cmdgraph: do_goto edge 't(ry)' missing required proc");

    check_str("do_pop edge missing proc msg",
        throw_msg([]{
            Engine e; e.add_state("r","r> ");
            e.add_command("r","c(ommit)",EdgeKind::DoPop);
        }),
        "cmdgraph: do_pop edge 'c(ommit)' missing required proc");
}

// ── Coverage completers ───────────────────────────────────────────────────────

static ActionResult act_do_pop_fail(const ArgList&, const std::string&) {
    return action_error("do_pop error message");
}

static void test_unmatched_quotes() {
    std::ostringstream oss;
    Engine eng = build_eng(&oss, &oss);

    // Unmatched quote in the command name position: the raw-substring
    // splitter treats the rest of the input as inside-quote, so the cmd
    // name is taken literally (including the leading quote) and falls
    // through the prefix matcher as an unknown — matches Tcl/Fortran.
    check_int("unmatched quote in cmd → RC_UNKNOWN",
              rc(eng.dispatch("\"unterminated")), RC_UNKNOWN);

    // Unmatched quote in args without a spec (no-spec path in validate_and_build)
    Engine eng2;
    eng2.set_io(nullptr, &oss, &oss);
    eng2.add_state("s", "s> ");
    eng2.add_command("s", "a(ct)", EdgeKind::Action, {.proc=act_outer});  // no arg spec
    eng2.add_command("s", "q",    EdgeKind::Quit);
    eng2.finalize("s");
    check_int("unmatched quote no-spec → RC_ERROR",
              rc(eng2.dispatch("act \"unterminated")), RC_ERROR);

    // Unmatched quote with a non-rest arg spec
    eng.reset();
    check_int("unmatched quote in char arg → RC_ERROR",
              rc(eng.dispatch("word \"unterminated")), RC_ERROR);

    // Unmatched quote in lead section of a rest command (tokenize throws → caught at line 157)
    Engine eng3;
    eng3.set_io(nullptr, &oss, &oss);
    eng3.add_state("s", "s> ");
    eng3.add_command("s", "r(est)", EdgeKind::Action,
                     {.proc=act_rest, .args={arg_is_char("label"), arg_is_rest("body")}});
    eng3.add_command("s", "q", EdgeKind::Quit);
    eng3.finalize("s");
    check_int("unmatched quote in rest lead → RC_ERROR",
              rc(eng3.dispatch("rest \"unterminated body")), RC_ERROR);

    // Embedded quote in middle of unquoted lead token → balanced_quotes catches it (line 179)
    check_int("embedded quote in unquoted lead → RC_ERROR",
              rc(eng3.dispatch("rest foo\"bar hello world")), RC_ERROR);
}

static void test_builder_errors2() {
    auto throws = [](auto fn) -> bool {
        try { fn(); return false; }
        catch (const std::runtime_error&) { return true; }
    };

    // add_state after finalize
    check_bool("add_state after finalize throws",
        throws([]{
            Engine e; e.add_state("r","r> "); e.add_command("r","q",EdgeKind::Quit);
            e.finalize("r"); e.add_state("extra","e> ");
        }), true);

    // add_command after finalize
    check_bool("add_command after finalize throws",
        throws([]{
            Engine e; e.add_state("r","r> "); e.add_command("r","q",EdgeKind::Quit);
            e.finalize("r"); e.add_command("r","x",EdgeKind::Action,{.proc=act_outer});
        }), true);

    // add_include after finalize
    check_bool("add_include after finalize throws",
        throws([]{
            Engine e; e.add_state("r","r> "); e.add_command("r","q",EdgeKind::Quit);
            e.finalize("r"); e.add_include("r","x");
        }), true);

    // add_include unknown state
    check_bool("add_include unknown state throws",
        throws([]{
            Engine e; e.add_state("r","r> ");
            e.add_include("nosuch","r");
        }), true);

    // set_on_enter after finalize
    check_bool("set_on_enter after finalize throws",
        throws([]{
            Engine e; e.add_state("r","r> "); e.add_command("r","q",EdgeKind::Quit);
            e.finalize("r");
            e.set_on_enter("r", [](const std::string&){});
        }), true);

    // set_on_enter unknown state
    check_bool("set_on_enter unknown state throws",
        throws([]{
            Engine e; e.add_state("r","r> ");
            e.set_on_enter("nosuch", [](const std::string&){});
        }), true);

    // finalize already finalized
    check_bool("finalize already finalized throws",
        throws([]{
            Engine e; e.add_state("r","r> "); e.add_command("r","q",EdgeKind::Quit);
            e.finalize("r"); e.finalize("r");
        }), true);

    // finalize with abstract target state
    check_bool("goto abstract target throws at finalize",
        throws([]{
            Engine e;
            e.add_state("abst");           // no prompt → abstract
            e.add_state("r","r> ");
            e.add_command("r","g",EdgeKind::Goto,{.target="abst"});
            e.finalize("r");
        }), true);

    // finalize with abstract initial state
    check_bool("abstract initial state throws at finalize",
        throws([]{
            Engine e;
            e.add_state("abst");           // no prompt → abstract
            e.finalize("abst");
        }), true);
}

static void test_finalize_include_merge() {
    // Include where two sources share a command spec → merge dedup (line 418)
    std::ostringstream oss;
    Engine eng;
    eng.set_io(nullptr, &oss, &oss);
    int count_a = 0, count_b = 0;
    auto act_a = [&](const ArgList&, const std::string&) -> ActionResult {
        ++count_a; return action_ok();
    };
    auto act_b = [&](const ArgList&, const std::string&) -> ActionResult {
        ++count_b; return action_ok();
    };
    eng.add_state("src1");
    eng.add_command("src1", "x(tra)", EdgeKind::Action, {.proc=act_a});
    eng.add_state("src2");
    eng.add_command("src2", "x(tra)", EdgeKind::Action, {.proc=act_b});
    eng.add_state("root", std::string("r> "));
    eng.add_include("root", "src1");
    eng.add_include("root", "src2");  // src2's "x(tra)" overrides src1's (dedup)
    eng.add_command("root", "q(uit)", EdgeKind::Quit);
    eng.finalize("root");

    count_a = 0; count_b = 0;
    check_int("include dedup: dispatches", rc(eng.dispatch("xtra")), RC_OK);
    check_int("include dedup: later wins", count_b, 1);
    check_int("include dedup: earlier gone", count_a, 0);
}

static void test_finalize_unknown_include() {
    // Include pointing to nonexistent state → finalize throws
    auto throws = []() -> bool {
        try {
            Engine e;
            e.add_state("root","r> ");
            e.add_include("root","phantom");
            e.add_command("root","q",EdgeKind::Quit);
            e.finalize("root");
            return false;
        } catch (const std::runtime_error&) { return true; }
    };
    check_bool("finalize unknown include state throws", throws(), true);
}

static void test_do_pop_errmsg() {
    // DO_POP action that errors with a message (lines 335-336 in cmdgraph.cxx)
    std::ostringstream oss;
    Engine eng;
    eng.set_io(nullptr, &oss, &oss);
    eng.add_state("home", std::string("h> "));
    eng.add_state("detail", std::string("d> "));
    eng.add_command("home", "g(o)", EdgeKind::Goto, {.target="detail"});
    eng.add_command("detail", "c(ommit)", EdgeKind::DoPop, {.proc=act_do_pop_fail});
    eng.add_command("detail", "b(ack)", EdgeKind::Pop);
    eng.finalize("home");

    (void)eng.dispatch("go");
    check_int("do_pop errmsg → RC_ERROR", rc(eng.dispatch("commit")), RC_ERROR);
    check_str("do_pop errmsg in last_error", eng.last_error, "do_pop error message");
    check_str("do_pop errmsg stays in state", eng.current_state(), "detail");
}

static void test_run_method() {
    // Test run() by feeding it a script via a stringstream
    std::istringstream input("action\naction\nquit\n");
    std::ostringstream out;
    Engine eng;
    eng.set_io(&input, &out, nullptr);
    eng.add_state("root", std::string("r> "));
    eng.add_command("root", "a(ction)", EdgeKind::Action, {.proc=act_outer});
    eng.add_command("root", "q(uit)",   EdgeKind::Quit);
    eng.finalize("root");

    g_outer_count = 0;
    eng.run();
    check_int("run: dispatched both actions", g_outer_count, 2);
    check_bool("run: stopped after quit",     eng.is_running(), false);
}

static void test_run_file_missing_stat() {
    // run_file on a missing file.  Parity contract (matches Tcl/Fortran):
    //   ok==false && *out_line==0  → file-open failure (out_stat unchanged)
    //   ok==false && *out_line>0   → dispatch failure on that line
    // last_error and *out_errmsg both carry "could not open script file: <path>".
    std::ostringstream oss;
    Engine eng = build_eng(&oss, &oss);
    RC stat = RC::Ok;
    int line = -1;
    std::string errmsg;
    const std::string path = "/tmp/cmdgraph_cpp_nosuchfile_utest.txt";
    bool ok = eng.run_file(path, false, &stat, &line, &errmsg);
    check_bool("run_file missing returns false",         !ok,            true);
    check_int ("run_file missing line is 0 (open-fail)", line,           0);
    check_str ("run_file missing last_error canonical",  eng.last_error,
               "could not open script file: " + path);
    check_str ("run_file missing out_errmsg canonical",  errmsg,
               "could not open script file: " + path);
}

static void test_reset_before_finalize() {
    // reset() before finalize throws (line 567)
    auto throws = []() -> bool {
        try { Engine e; e.reset(); return false; }
        catch (const std::runtime_error&) { return true; }
    };
    check_bool("reset before finalize throws", throws(), true);
}

static void test_command_name_not_word() {
    // Parity contract: the command name is a raw substring (no type
    // inference), so a numeric first token is just a literal command
    // name that doesn't match anything → RC_UNKNOWN via the info channel
    // (matches Tcl/Fortran; the prior C++ "command name must be a word"
    // path is gone).
    std::ostringstream oss;
    Engine eng = build_eng(&oss, &oss);
    check_int("numeric cmd name → RC_UNKNOWN",
              rc(eng.dispatch("42 foo")), RC_UNKNOWN);
    check_str("numeric cmd name last_message", eng.last_message, "unknown: 42");
}

// ── main ──────────────────────────────────────────────────────────────────────

// ── swap / do_swap ────────────────────────────────────────────────────────────

static int         g_swap_enter_a = 0;
static int         g_swap_enter_b = 0;
static std::string g_swap_ctx_a;

static ActionResult act_swap_pick(const ArgList& args, const std::string&) {
    // id<=0 → empty value (veto the swap); else return "<id>" as context.
    int id = args.empty() ? 0 : arg_int(args[0]);
    if (id > 0) {
        char buf[16];
        std::snprintf(buf, sizeof(buf), "%d", id);
        return action_ok(buf);
    }
    return action_ok();
}

static void enter_swap_a(const std::string& ctx) { ++g_swap_enter_a; g_swap_ctx_a = ctx; }
static void enter_swap_b(const std::string&)     { ++g_swap_enter_b; }

// root --go--> toola <==swap==> toolb ; the toola<->toolb swap cycle
// finalizes cleanly, proving swap edges are DAG-exempt.
static Engine build_swap_eng(std::ostream* err = nullptr) {
    Engine eng;
    if (err) eng.set_io(nullptr, nullptr, err);
    eng.add_state("root", "r> ");
    eng.add_command("root", "g(o)",   EdgeKind::Goto, {.target="toola"});
    eng.add_command("root", "q(uit)", EdgeKind::Quit);
    eng.add_state("toola", "a> ");
    eng.set_on_enter("toola", enter_swap_a);
    eng.add_command("toola", "n(ext)", EdgeKind::Swap, {.target="toolb"});
    eng.add_command("toola", "b(ack)", EdgeKind::Pop);
    eng.add_state("toolb", "b> ");
    eng.set_on_enter("toolb", enter_swap_b);
    eng.add_command("toolb", "p(ick)", EdgeKind::DoSwap,
                    {.target="toola", .proc=act_swap_pick, .args={arg_is_int("id")}});
    eng.add_command("toolb", "f(ail)", EdgeKind::DoSwap,
                    {.target="toola", .proc=act_fail_msg});
    eng.add_command("toolb", "b(ack)", EdgeKind::Pop);
    eng.finalize("root");
    return eng;
}

static void test_swap() {
    // SWAP replaces the top frame (pop-then-push): after go+next, a single
    // back lands in root, not toola — the depth did not grow.
    g_swap_enter_a = g_swap_enter_b = 0;
    Engine eng = build_swap_eng();
    check_str("swap: starts in root", eng.current_state(), "root");
    check_int("swap: go rc", rc(eng.dispatch("go")), RC_TRANSITIONED);
    check_str("swap: in toola", eng.current_state(), "toola");
    check_int("swap: on_enter toola", g_swap_enter_a, 1);

    check_int("swap: next rc", rc(eng.dispatch("next")), RC_TRANSITIONED);
    check_str("swap: in toolb", eng.current_state(), "toolb");
    check_str("swap: empty context", eng.current_context(), "");
    check_int("swap: on_enter toolb", g_swap_enter_b, 1);
    check_int("swap: depth unchanged", (int)eng.state_path().size(), 2);

    // replace-not-push: one back returns to root
    check_int("swap: back rc", rc(eng.dispatch("back")), RC_TRANSITIONED);
    check_str("swap: popped to root", eng.current_state(), "root");
}

static void test_do_swap() {
    // DO_SWAP: error stays (RC_Error); empty return stays (RC_Ok); non-empty
    // return replaces the top frame with that value as context.
    std::ostringstream oss;
    g_swap_enter_a = g_swap_enter_b = 0;
    g_swap_ctx_a.clear();
    Engine eng = build_swap_eng(&oss);
    (void)eng.dispatch("go");
    (void)eng.dispatch("next");

    check_int("do_swap: error rc", rc(eng.dispatch("fail")), RC_ERROR);
    check_str("do_swap: error stays", eng.current_state(), "toolb");
    check_int("do_swap: empty rc", rc(eng.dispatch("pick 0")), RC_OK);
    check_str("do_swap: empty stays", eng.current_state(), "toolb");

    g_swap_enter_a = 0;
    check_int("do_swap: pick rc", rc(eng.dispatch("pick 7")), RC_TRANSITIONED);
    check_str("do_swap: in toola", eng.current_state(), "toola");
    check_str("do_swap: context is 7", eng.current_context(), "7");
    check_int("do_swap: on_enter toola", g_swap_enter_a, 1);
    check_str("do_swap: on_enter saw ctx", g_swap_ctx_a, "7");
    check_int("do_swap: depth unchanged", (int)eng.state_path().size(), 2);

    check_int("do_swap: back rc", rc(eng.dispatch("back")), RC_TRANSITIONED);
    check_str("do_swap: popped to root", eng.current_state(), "root");
}

static void test_swap_builder_errors() {
    auto throw_msg = [](auto fn) -> std::string {
        try { fn(); return {}; }
        catch (const std::runtime_error& e) { return e.what(); }
    };

    check_str("swap edge missing target msg",
        throw_msg([]{
            Engine e; e.add_state("r","r> ");
            e.add_command("r","n(ext)",EdgeKind::Swap);
        }),
        "cmdgraph: swap edge 'n(ext)' missing required target");

    check_str("do_swap edge missing target msg",
        throw_msg([]{
            Engine e; e.add_state("r","r> ");
            e.add_command("r","p(ick)",EdgeKind::DoSwap,{.proc=act_outer});
        }),
        "cmdgraph: do_swap edge 'p(ick)' missing required target");

    check_str("do_swap edge missing proc msg",
        throw_msg([]{
            Engine e; e.add_state("r","r> "); e.add_state("d","d> ");
            e.add_command("r","p(ick)",EdgeKind::DoSwap,{.target="d"});
        }),
        "cmdgraph: do_swap edge 'p(ick)' missing required proc");

    auto throws = [](auto fn) -> bool {
        try { fn(); return false; }
        catch (const std::runtime_error&) { return true; }
    };
    check_bool("swap unknown target throws at finalize",
        throws([]{
            Engine e; e.add_state("a","a> ");
            e.add_command("a","n",EdgeKind::Swap,{.target="ghost"});
            e.finalize("a");
        }), true);
}

static void test_swap_not_cycle() {
    // swap/do_swap replace the top frame (pop-then-push) so a mutually-swapping
    // a<->b pair is inherently cyclic yet valid — exempt from the DAG check.
    auto throws = [](auto fn) -> bool {
        try { fn(); return false; }
        catch (const std::runtime_error&) { return true; }
    };
    check_bool("swap/do_swap not a cycle edge",
        throws([]{
            Engine e;
            e.add_state("a","a> ");
            e.add_state("b","b> ");
            e.add_command("a","n",EdgeKind::Swap,{.target="b"});
            e.add_command("b","p",EdgeKind::DoSwap,{.target="a", .proc=act_outer});
            e.finalize("a");
        }), false);
}

int main() {
    test_initial_state();
    test_action_edge();
    test_prefix_matching();
    test_empty_line();
    test_unknown();
    test_ambiguous_engine();
    test_goto();
    test_do_goto_success();
    test_do_goto_fail();
    test_pop();
    test_pop_to_empty();
    test_do_pop();
    test_quit();
    test_arg_int();
    test_arg_real();
    test_arg_char();
    test_includes();
    test_reset();
    test_run_file();
    test_io_suppress();
    test_introspection();
    test_help();
    test_rest_of_line();
    test_array_specs();
    test_action_errmsg();
    test_constructors();
    test_builder_errors();
    test_unmatched_quotes();
    test_builder_errors2();
    test_finalize_include_merge();
    test_finalize_unknown_include();
    test_do_pop_errmsg();
    test_run_method();
    test_run_file_missing_stat();
    test_reset_before_finalize();
    test_command_name_not_word();
    test_swap();
    test_do_swap();
    test_swap_builder_errors();
    test_swap_not_cycle();

    check_int("version major",  CMDGRAPH_VERSION.major, 1);
    check_int("version minor",  CMDGRAPH_VERSION.minor, 3);
    check_int("version patch",  CMDGRAPH_VERSION.patch, 0);
    check_str("version string", CMDGRAPH_VERSION.string(), "1.3.0");

    std::cout << "\nResults: " << (g_pass + g_fail) << " tests, "
              << g_pass << " passed, " << g_fail << " failed\n";
    return g_fail ? 1 : 0;
}
