#include "cmdgraph.hxx"

#include <algorithm>
#include <charconv>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace cmdgraph {

//──── Free functions ──────────────────────────────────────────────────────────

ActionResult action_ok(std::optional<std::string> ctx) {
    return {false, std::move(ctx), std::nullopt};
}

ActionResult action_error(std::optional<std::string> msg) {
    return {true, std::nullopt, std::move(msg)};
}

ArgSpec arg_is_int (std::string n, bool opt) { return {std::move(n), ARG_INT,  opt}; }
ArgSpec arg_is_real(std::string n, bool opt) { return {std::move(n), ARG_REAL, opt}; }
ArgSpec arg_is_char(std::string n, bool opt) { return {std::move(n), ARG_CHAR, opt}; }
ArgSpec arg_is_rest(std::string n, bool opt) { return {std::move(n), ARG_REST, opt}; }

std::vector<ArgSpec> arg_int_n(std::string name, int n) {
    return std::vector<ArgSpec>(n, {std::move(name), ARG_INT, false});
}

std::vector<ArgSpec> arg_real_n(std::string name, int n) {
    return std::vector<ArgSpec>(n, {std::move(name), ARG_REAL, false});
}

//──── Engine: constructor ─────────────────────────────────────────────────────

Engine::Engine()
    : in_(&std::cin), out_(&std::cout), err_(&std::cerr) {}

//──── Helpers: parse spec ─────────────────────────────────────────────────────

static void parse_spec(const std::string& spec,
                        std::string& req, std::string& opt) {
    auto open  = spec.find('(');
    auto close = spec.find(')');
    if (open  != std::string::npos &&
        close != std::string::npos && close > open) {
        req = spec.substr(0, open);
        opt = spec.substr(open + 1, close - open - 1);
    } else {
        req = spec;
        opt = "";
    }
}

std::size_t Engine::find_state_(const std::string& name) const {
    auto it = std::ranges::find_if(states_, [&](const State& s){ return s.name == name; });
    return it == states_.end() ? std::string::npos
                               : static_cast<std::size_t>(it - states_.begin());
}

//──── Helpers: tokeniser ──────────────────────────────────────────────────────

[[nodiscard]] static bool balanced_quotes(const std::string& text) {
    for (std::size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '"') {
            ++i;
            while (i < text.size() && text[i] != '"') ++i;
            if (i >= text.size()) return false;
        }
    }
    return true;
}

struct Token {
    ArgValue    value;
    std::size_t end;   // index in source line just after this token
};

// Tokenise up to max_tokens from line starting at offset.
// Strips surrounding quotes (quoting forces string only if content
// is empty, otherwise int/real inference still applies — matches Fortran).
// Throws std::runtime_error on unmatched quote.
[[nodiscard]] static std::vector<Token> tokenize(const std::string& line,
                                    std::size_t offset   = 0,
                                    std::size_t max_toks = std::string::npos) {
    std::vector<Token> toks;
    std::size_t i = offset;
    std::size_t n = line.size();

    while (i < n && toks.size() < max_toks) {
        while (i < n && line[i] == ' ') ++i;
        if (i >= n) break;

        std::string raw;

        if (line[i] == '"') {
            ++i;
            while (i < n && line[i] != '"') raw += line[i++];
            if (i >= n)
                throw std::runtime_error("unmatched quote in arguments");
            ++i;  // consume closing "
        } else {
            while (i < n && line[i] != ' ') raw += line[i++];
        }

        // Type inference: try int → real → char (same order as Fortran).
        // from_chars is locale-independent and validates the full token.
        if (!raw.empty()) {
            int ival;
            auto [p1, e1] = std::from_chars(raw.data(), raw.data() + raw.size(), ival);
            if (e1 == std::errc{} && p1 == raw.data() + raw.size()) {
                toks.push_back({ival, i}); continue;
            }
            double dval;
            auto real_raw = raw;
            if (auto pos = real_raw.find_first_of("dD"); pos != std::string::npos)
                real_raw[pos] = 'e';
            auto [p2, e2] = std::from_chars(real_raw.data(), real_raw.data() + real_raw.size(), dval);
            if (e2 == std::errc{} && p2 == real_raw.data() + real_raw.size()) {
                toks.push_back({dval, i}); continue;
            }
        }
        toks.push_back({std::string{raw}, i});
    }
    return toks;
}

//──── Helpers: command rendering and arg validation ───────────────────────────

std::string Engine::cmd_usage_(const Engine::Command& cmd) {
    std::string s = cmd.spec;
    for (const auto& a : cmd.args) {
        const char* k = (a.kind==ARG_INT) ? "int"
                      : (a.kind==ARG_REAL) ? "real"
                      : (a.kind==ARG_REST) ? "rest" : "char";
        std::string slot = a.name + ":" + k;
        s += a.optional ? " [" + slot + "]" : " <" + slot + ">";
    }
    return s;
}

// Validate and build ArgList. spec may be empty (no validation, best-effort
// types). Returns empty string on success, diagnostic message on failure.
[[nodiscard]] static std::string validate_and_build(const std::string& line,
                                       std::size_t arg_start,
                                       const std::vector<ArgSpec>& spec,
                                       ArgList& out) {
    out.clear();

    if (spec.empty()) {
        // No spec: tokenise everything, pass as-is
        if (!balanced_quotes(line.substr(arg_start)))
            return "unmatched quote in arguments";
        auto toks = tokenize(line, arg_start);
        std::ranges::transform(toks, std::back_inserter(out), [](const Token& t){ return t.value; });
        return {};
    }

    bool has_rest = !spec.empty() && spec.back().kind == ARG_REST;
    std::size_t n_lead = spec.size() - (has_rest ? 1 : 0);

    // n_required = 1-based position of the last non-optional lead slot
    // (rest slot excluded — it is handled separately at the tail)
    int n_required = 0;
    for (int i = 0; i < (int)n_lead; ++i)
        if (!spec[i].optional) n_required = i + 1;

    std::vector<Token> toks;
    if (has_rest) {
        try { toks = tokenize(line, arg_start, n_lead); }
        catch (const std::runtime_error& e) { return e.what(); }
        // Check balance only over the lead portion consumed
        std::size_t lead_end = toks.empty() ? arg_start : toks.back().end;
        if (!balanced_quotes(line.substr(arg_start, lead_end - arg_start)))
            return "unmatched quote in arguments";
    } else {
        if (!balanced_quotes(line.substr(arg_start)))
            return "unmatched quote in arguments";
        try { toks = tokenize(line, arg_start); }
        catch (const std::runtime_error& e) { return e.what(); }
    }

    // Count check (ARG_REST contributes 0 or 1 depending on whether tail exists)
    if ((int)toks.size() < n_required)
        return "missing required argument <" + spec[toks.size()].name + ">";
    if (!has_rest && toks.size() > spec.size())
        return "unexpected extra argument";

    // Type check non-rest tokens
    for (std::size_t i = 0; i < toks.size(); ++i) {
        const auto& s = spec[i];
        const auto& v = toks[i].value;
        bool ok = true;
        switch (s.kind) {
            case ARG_INT:  ok = std::holds_alternative<int>(v);         break;
            case ARG_REAL: ok = std::holds_alternative<double>(v);      break;
            case ARG_CHAR: ok = std::holds_alternative<std::string>(v); break;
            default: break;  // ARG_REST: no type check
        }
        if (!ok) {
            const char* expected = (s.kind==ARG_INT) ? "integer"
                                 : (s.kind==ARG_REAL) ? "real" : "string";
            return "argument <" + s.name + "> expects " + expected;
        }
        out.push_back(v);
    }

    // Append rest arg if present
    if (has_rest) {
        std::size_t rest_start = toks.empty() ? arg_start : toks.back().end;
        while (rest_start < line.size() && line[rest_start] == ' ') ++rest_start;
        std::string tail = line.substr(rest_start);
        if (!tail.empty() || !spec.back().optional)
            out.push_back(tail);
    }

    return {};
}

//──── Helpers: prefix matching ────────────────────────────────────────────────

bool Engine::cmd_matches_(const Engine::Command& cmd, const std::string& input) {
    std::string full = cmd.req + cmd.opt;
    return input.size() >= cmd.req.size()
        && input.size() <= full.size()
        && full.compare(0, input.size(), input) == 0;
}

//──── Helpers: I/O ───────────────────────────────────────────────────────────

void Engine::emit_error_(const std::string& msg) {
    last_error = msg;
    if (err_) *err_ << msg << '\n';
}

void Engine::emit_help_(const std::vector<Command>& cmds) {
    std::size_t max_w = 0;
    for (const auto& c : cmds)
        max_w = std::max(max_w, Engine::cmd_usage_(c).size());
    std::ostringstream oss;
    for (const auto& c : cmds) {
        std::string u = Engine::cmd_usage_(c);
        oss << "  " << u;
        if (!c.help.empty())
            oss << std::string(max_w - u.size() + 2, ' ') << c.help;
        oss << '\n';
    }
    std::string msg = oss.str();
    if (!msg.empty() && msg.back() == '\n') msg.pop_back();
    last_message = msg;
    if (out_) *out_ << msg << '\n';
}

//──── DAG validation ─────────────────────────────────────────────────────────

void Engine::dfs_(const std::vector<Engine::State>& states,
                 std::size_t idx, std::vector<int>& color) {
    if (color[idx] == 2) return;
    if (color[idx] == 1)
        throw std::runtime_error(
            "cmdgraph: cycle involving state '" + states[idx].name + "'");
    color[idx] = 1;
    for (const auto& cmd : states[idx].commands) {
        if (cmd.kind == EdgeKind::Goto || cmd.kind == EdgeKind::DoGoto) {
            auto it = std::ranges::find_if(states, [&](const State& s){
                return s.name == cmd.target && s.prompt.has_value();
            });
            if (it != states.end())
                Engine::dfs_(states, static_cast<std::size_t>(it - states.begin()), color);
        }
    }
    color[idx] = 2;
}

//──── apply_edge ─────────────────────────────────────────────────────────────

RC Engine::apply_edge_(const Command& cmd, const ArgList& args) {
    const std::string& ctx = stack_.empty() ? std::string{} : stack_.back().context;

    auto push_state = [&](std::size_t idx, std::string new_ctx) {
        stack_.push_back({idx, std::move(new_ctx)});
        if (states_[idx].on_enter)
            states_[idx].on_enter(stack_.back().context);
    };

    switch (cmd.kind) {

    case EdgeKind::Action: {
        if (!cmd.proc) return RC::Ok;
        auto r = cmd.proc(args, ctx);
        if (r.errored) {
            if (r.errmsg) emit_error_(*r.errmsg);
            return RC::Error;
        }
        return RC::Ok;
    }

    case EdgeKind::Goto: {
        push_state(find_state_(cmd.target), {});
        return RC::Transitioned;
    }

    case EdgeKind::DoGoto: {
        if (!cmd.proc) return RC::Ok;
        auto r = cmd.proc(args, ctx);
        if (r.errored) {
            if (r.errmsg) emit_error_(*r.errmsg);
            return RC::Error;
        }
        if (r.value && !r.value->empty()) {
            push_state(find_state_(cmd.target), *r.value);
            return RC::Transitioned;
        }
        return RC::Ok;
    }

    case EdgeKind::Pop: {
        stack_.pop_back();
        return stack_.empty() ? RC::Exited : RC::Transitioned;
    }

    case EdgeKind::DoPop: {
        if (!cmd.proc) { stack_.pop_back(); return stack_.empty() ? RC::Exited : RC::Transitioned; }
        auto r = cmd.proc(args, ctx);
        if (r.errored) {
            if (r.errmsg) emit_error_(*r.errmsg);
            return RC::Error;
        }
        stack_.pop_back();
        return stack_.empty() ? RC::Exited : RC::Transitioned;
    }

    case EdgeKind::Quit:
        stack_.clear();
        return RC::Exited;
    }
    return RC::Ok;  // unreachable
}

//──── Construction ───────────────────────────────────────────────────────────

void Engine::add_state(std::string name, std::optional<std::string> prompt) {
    if (finalized_)
        throw std::runtime_error("cmdgraph: add_state after finalize");
    if (find_state_(name) != std::string::npos)
        throw std::runtime_error("cmdgraph: state '" + name + "' already exists");
    State s;
    s.name   = std::move(name);
    s.prompt = std::move(prompt);
    states_.push_back(std::move(s));
}

void Engine::add_command(std::string state_name, std::string spec,
                          EdgeKind kind, CommandOptions opts) {
    if (finalized_)
        throw std::runtime_error("cmdgraph: add_command after finalize");
    std::size_t idx = find_state_(state_name);
    if (idx == std::string::npos)
        throw std::runtime_error("cmdgraph: unknown state '" + state_name + "'");

    for (std::size_t i = 0; i + 1 < opts.args.size(); ++i)
        if (opts.args[i].kind == ARG_REST)
            throw std::runtime_error(
                "cmdgraph: ARG_REST must be the last spec (command '" + spec + "')");

    Command cmd;
    cmd.spec   = spec;
    parse_spec(spec, cmd.req, cmd.opt);
    cmd.kind   = kind;
    cmd.target = std::move(opts.target);
    cmd.proc   = std::move(opts.proc);
    cmd.help   = std::move(opts.help);
    cmd.args   = std::move(opts.args);
    states_[idx].own_cmds.push_back(std::move(cmd));
}

void Engine::add_include(std::string state_name, std::string included) {
    if (finalized_)
        throw std::runtime_error("cmdgraph: add_include after finalize");
    std::size_t idx = find_state_(state_name);
    if (idx == std::string::npos)
        throw std::runtime_error("cmdgraph: unknown state '" + state_name + "'");
    states_[idx].includes.push_back(std::move(included));
}

void Engine::set_on_enter(std::string state_name, OnEnterFn proc) {
    if (finalized_)
        throw std::runtime_error("cmdgraph: set_on_enter after finalize");
    std::size_t idx = find_state_(state_name);
    if (idx == std::string::npos)
        throw std::runtime_error("cmdgraph: unknown state '" + state_name + "'");
    states_[idx].on_enter = std::move(proc);
}

void Engine::finalize(std::string initial) {
    if (finalized_)
        throw std::runtime_error("cmdgraph: already finalized");

    // Resolve includes — own commands take precedence; later includes win over earlier.
    for (auto& st : states_) {
        std::vector<Command> merged;
        for (const auto& inc_name : st.includes) {
            std::size_t ii = find_state_(inc_name);
            if (ii == std::string::npos)
                throw std::runtime_error(
                    "cmdgraph: state '" + st.name + "' includes unknown '" + inc_name + "'");
            for (const auto& c : states_[ii].own_cmds) {
                auto it = std::find_if(merged.begin(), merged.end(),
                    [&](const Command& m){ return m.spec == c.spec; });
                if (it != merged.end()) *it = c; else merged.push_back(c);
            }
        }
        for (const auto& c : st.own_cmds) {
            auto it = std::find_if(merged.begin(), merged.end(),
                [&](const Command& m){ return m.spec == c.spec; });
            if (it != merged.end()) *it = c; else merged.push_back(c);
        }
        st.commands = std::move(merged);
    }

    // Validate targets and initial state
    std::size_t init = find_state_(initial);
    if (init == std::string::npos)
        throw std::runtime_error("cmdgraph: initial state '" + initial + "' not found");
    if (!states_[init].prompt)
        throw std::runtime_error("cmdgraph: initial state '" + initial + "' is abstract");

    for (const auto& st : states_) {
        for (const auto& cmd : st.commands) {
            if (cmd.kind == EdgeKind::Goto || cmd.kind == EdgeKind::DoGoto) {
                std::size_t ti = find_state_(cmd.target);
                if (ti == std::string::npos)
                    throw std::runtime_error(
                        "cmdgraph: '" + cmd.spec + "' in '" + st.name +
                        "' targets unknown state '" + cmd.target + "'");
                if (!states_[ti].prompt)
                    throw std::runtime_error(
                        "cmdgraph: '" + cmd.spec + "' in '" + st.name +
                        "' targets abstract state '" + cmd.target + "'");
            }
        }
    }

    // DAG check on goto/do_goto edges between concrete states
    std::vector<int> color(states_.size(), 0);
    Engine::dfs_(states_, init, color);

    initial_state_idx_ = init;
    finalized_ = true;
    stack_.push_back({init, {}});
    if (states_[init].on_enter) states_[init].on_enter({});
}

//──── Execution ──────────────────────────────────────────────────────────────

void Engine::set_io(std::istream* in, std::ostream* out, std::ostream* err) {
    if (in)  in_  = in;
    if (out) out_ = out;
    if (err) err_ = err;
}

RC Engine::dispatch(std::string line) {
    if (!finalized_ || stack_.empty()) return RC::Exited;

    // Strip trailing whitespace
    while (!line.empty() && line.back() == ' ') line.pop_back();
    if (line.empty()) return RC::Ok;

    // Extract command name (first token — must be a bare word)
    std::vector<Token> name_tok;
    try { name_tok = tokenize(line, 0, 1); }
    catch (const std::runtime_error& e) { emit_error_(e.what()); return RC::Error; }

    if (name_tok.empty()) return RC::Ok;
    if (!std::holds_alternative<std::string>(name_tok[0].value)) {
        emit_error_("command name must be a word");
        return RC::Error;
    }
    std::string cmd_name = std::get<std::string>(name_tok[0].value);
    std::size_t arg_off  = name_tok[0].end;

    const auto& cmds = states_[stack_.back().state_idx].commands;

    // Check for graph-defined help before the built-in
    bool graph_has_help = std::any_of(cmds.begin(), cmds.end(),
        [](const Command& c){ return c.spec == "help" || c.spec == "?"; });

    if (!graph_has_help && (cmd_name == "help" || cmd_name == "?")) {
        emit_help_(cmds);
        return RC::Ok;
    }

    // Prefix matching
    std::vector<const Command*> matches;
    for (const auto& c : cmds)
        if (Engine::cmd_matches_(c, cmd_name)) matches.push_back(&c);

    if (matches.empty()) {
        emit_error_("unknown: " + cmd_name);
        return RC::Unknown;
    }
    if (matches.size() > 1) {
        std::string msg = "ambiguous '" + cmd_name + "':";
        for (const auto* c : matches) msg += " " + c->spec;
        emit_error_(msg);
        return RC::Ambiguous;
    }

    const Command& cmd = *matches[0];

    ArgList args;
    std::string err = validate_and_build(line, arg_off, cmd.args, args);
    if (!err.empty()) { emit_error_(err); return RC::Error; }

    return apply_edge_(cmd, args);
}

void Engine::run() {
    std::string line;
    while (is_running()) {
        if (out_) {
            const auto& st = states_[stack_.back().state_idx];
            if (st.prompt) { *out_ << *st.prompt; out_->flush(); }
        }
        if (!std::getline(*in_, line)) break;
        (void)dispatch(line);  // loop condition is is_running(); RC not needed here
    }
}

bool Engine::run_file(std::string path, bool echo,
                       RC* out_stat, int* out_line) {
    std::ifstream f(path);
    if (!f) {
        if (out_stat) *out_stat = RC::Error;
        if (out_line) *out_line = 0;
        return false;
    }
    std::string line;
    int lno = 0;
    while (is_running() && std::getline(f, line)) {
        ++lno;
        if (echo && out_) *out_ << line << '\n';
        RC rc = dispatch(line);
        if (rc == RC::Exited) break;
        if (rc != RC::Ok && rc != RC::Transitioned) {
            if (out_stat) *out_stat = rc;
            if (out_line) *out_line = lno;
            return false;
        }
    }
    if (out_stat) *out_stat = RC::Ok;
    if (out_line) *out_line = lno;
    return true;
}

void Engine::reset() {
    if (!finalized_)
        throw std::runtime_error("cmdgraph: reset before finalize");
    stack_.clear();
    stack_.push_back({initial_state_idx_, {}});
    last_message.clear();
    last_error.clear();
}

//──── Inspection ─────────────────────────────────────────────────────────────

std::string Engine::current_state() const {
    return stack_.empty() ? "" : states_[stack_.back().state_idx].name;
}

std::string Engine::current_context() const {
    return stack_.empty() ? "" : stack_.back().context;
}

bool Engine::is_running() const {
    return finalized_ && !stack_.empty();
}

std::vector<CommandInfo> Engine::available_commands() const {
    if (stack_.empty()) return {};
    const auto& cmds = states_[stack_.back().state_idx].commands;
    std::vector<CommandInfo> result(cmds.size());
    std::ranges::transform(cmds, result.begin(), [](const Command& c) {
        return CommandInfo{c.spec, c.req, c.opt, c.kind, c.target, c.args, c.help};
    });
    return result;
}

std::vector<std::string> Engine::state_path() const {
    std::vector<std::string> v(stack_.size());
    std::ranges::transform(stack_, v.begin(),
        [&](const StackEntry& e){ return states_[e.state_idx].name; });
    return v;
}

} // namespace cmdgraph
