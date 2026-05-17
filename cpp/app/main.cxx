// cmdgraph C++ library demo — a tiny interactive "library" REPL.
// Mirrors fortran/app/main.f90.

#include "cmdgraph.hxx"

#include <algorithm>
#include <cctype>
#include <iostream>
#include <sstream>
#include <string>

using namespace cmdgraph;

static constexpr int N_BOOKS = 3;

static const char* titles[N_BOOKS] = {
    "The Pragmatic Programmer",
    "Structure and Interpretation of Computer Programs",
    "The C Programming Language"
};

static const char* summaries[N_BOOKS] = {
    "Hunt & Thomas's tour of practical software craft.",
    "The SICP — abstractions, procedures, the meta-circular evaluator.",
    "K&R — the book that taught a generation what a pointer is."
};

static std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
        [](unsigned char c){ return std::tolower(c); });
    return s;
}

static ActionResult act_list(const ArgList&, const std::string&) {
    for (int i = 0; i < N_BOOKS; ++i)
        std::cout << "  " << (i+1) << "  " << titles[i] << '\n';
    return action_ok();
}

static ActionResult act_open(const ArgList& args, const std::string&) {
    int id = arg_int(args[0]);
    if (id < 1 || id > N_BOOKS) {
        return action_error("no book with id " + std::to_string(id) + " (try `list`)");
    }
    return action_ok(std::to_string(id));
}

static ActionResult act_find(const ArgList& args, const std::string&) {
    std::string needle = lower(arg_str(args[0]));
    int hits = 0;
    for (int i = 0; i < N_BOOKS; ++i) {
        if (lower(titles[i]).find(needle) != std::string::npos) {
            std::cout << "  " << (i+1) << "  " << titles[i] << '\n';
            ++hits;
        }
    }
    if (!hits) std::cout << "  (no matches)\n";
    return action_ok();
}

static ActionResult act_hello(const ArgList&, const std::string&) {
    std::cout << "Welcome to the library.\n";
    return action_ok();
}

static ActionResult act_read(const ArgList&, const std::string& ctx) {
    try {
        int id = std::stoi(ctx);
        std::cout << summaries[id - 1] << '\n';
    } catch (...) { return action_error(); }
    return action_ok();
}

static ActionResult act_title(const ArgList&, const std::string& ctx) {
    try {
        int id = std::stoi(ctx);
        std::cout << titles[id - 1] << '\n';
    } catch (...) { return action_error(); }
    return action_ok();
}

static void enter_book(const std::string& ctx) {
    try {
        int id = std::stoi(ctx);
        if (id >= 1 && id <= N_BOOKS)
            std::cout << "Opened: " << titles[id - 1] << '\n';
    } catch (...) {}
}

int main() {
    Engine eng;

    eng.add_state("library", "library> ");
    eng.add_command("library", "h(ello)", EdgeKind::Action,
                    {.proc=act_hello, .help="Print greeting"});
    eng.add_command("library", "l(ist)",  EdgeKind::Action,
                    {.proc=act_list,  .help="List books"});
    eng.add_command("library", "f(ind)",  EdgeKind::Action,
                    {.proc=act_find,  .help="Find in titles",
                     .args={arg_is_char("text")}});
    eng.add_command("library", "o(pen)",  EdgeKind::DoGoto,
                    {.target="book", .proc=act_open,
                     .help="Open book", .args={arg_is_int("id")}});
    eng.add_command("library", "q(uit)",  EdgeKind::Quit,
                    {.help="Exit"});

    eng.add_state("book", "book> ");
    eng.set_on_enter("book", enter_book);
    eng.add_command("book", "r(ead)",  EdgeKind::Action,
                    {.proc=act_read,  .help="Show summary"});
    eng.add_command("book", "t(itle)", EdgeKind::Action,
                    {.proc=act_title, .help="Show title"});
    eng.add_command("book", "b(ack)",  EdgeKind::Pop,
                    {.help="Back to library"});
    eng.add_command("book", "q(uit)",  EdgeKind::Quit,
                    {.help="Exit"});

    eng.finalize("library");

    std::cout << "cmdgraph C++ library demo — type `help` for commands\n";
    eng.run();
}
