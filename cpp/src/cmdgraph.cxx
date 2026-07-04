// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Simon Geard
//
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

ActionResult action_ok(const std::optional<std::string>& ctx) {
    return {false, ctx, std::nullopt};
}

ActionResult action_error(const std::optional<std::string>& msg) {
    return {true, std::nullopt, msg};
}

ArgSpec arg_is_int (const std::string& n, bool opt) { return {n, ARG_INT,  opt}; }
ArgSpec arg_is_real(const std::string& n, bool opt) { return {n, ARG_REAL, opt}; }
ArgSpec arg_is_char(const std::string& n, bool opt) { return {n, ARG_CHAR, opt}; }
ArgSpec arg_is_rest(const std::string& n, bool opt) { return {n, ARG_REST, opt}; }

std::vector<ArgSpec> arg_int_n(const std::string& name, int n) {
    return std::vector<ArgSpec>(n, {name, ARG_INT, false});
}

std::vector<ArgSpec> arg_real_n(const std::string& name, int n) {
    return std::vector<ArgSpec>(n, {name, ARG_REAL, false});
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
    std::size_t n_required = 0;
    for (std::size_t i = 0; i < n_lead; ++i)
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
    if (toks.size() < n_required)
        return "missing required argument <" + spec[toks.size()].name + ">";
    if (!has_rest && toks.size() > spec.size())
        return "unexpected extra argument";

    // Type check non-rest tokens. ARG_REAL accepts an integer token and
    // promotes it to double — the action sees a real-typed value in that slot,
    // matching Tcl validate_args and the Fortran post-validate normalisation.
    for (std::size_t i = 0; i < toks.size(); ++i) {
        const auto& s = spec[i];
        const auto& v = toks[i].value;
        bool ok = true;
        switch (s.kind) {
            case ARG_INT:  ok = std::holds_alternative<int>(v);         break;
            case ARG_REAL: ok = std::holds_alternative<double>(v)
                              || std::holds_alternative<int>(v);        break;
            case ARG_CHAR: ok = std::holds_alternative<std::string>(v); break;
            default: break;  // ARG_REST: no type check
        }
        if (!ok) {
            const char* expected = (s.kind==ARG_INT) ? "integer"
                                 : (s.kind==ARG_REAL) ? "real" : "string";
            return "argument <" + s.name + "> expects " + expected;
        }
        if (s.kind == ARG_REAL && std::holds_alternative<int>(v))
            out.push_back(static_cast<double>(std::get<int>(v)));
        else
            out.push_back(v);
    }

    // Append rest arg if present. Mirrors Tcl (cmdgraph-1.0.tm:543-544) and
    // Fortran: a non-empty tail is appended; an empty tail is omitted; an empty
    // tail in a required rest slot is the same "missing required argument" the
    // count check above raises for missing lead slots.
    if (has_rest) {
        std::size_t rest_start = toks.empty() ? arg_start : toks.back().end;
        while (rest_start < line.size() && line[rest_start] == ' ') ++rest_start;
        std::string tail = line.substr(rest_start);
        if (!tail.empty()) {
            out.push_back(tail);
        } else if (!spec.back().optional) {
            return "missing required argument <" + spec.back().name + ">";
        }
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

void Engine::emit_info_(const std::string& msg) {
    last_message = msg;
    if (out_) *out_ << msg << '\n';
}

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

// DFS over goto/do_goto edges between concrete states. On the first back-edge
// (target is gray), sets found=true with ancestor=target / descendant=u and
// unwinds. Mirrors Fortran find_cycle/dfs (cmdgraph_sm.f90:1245-1299) and Tcl
// detect_cycle (cmdgraph-1.0.tm:261).
void Engine::dfs_(const std::vector<Engine::State>& states,
                 std::size_t              u,
                 std::vector<int>&        color,
                 std::vector<std::size_t>& parent,
                 bool&                    found,
                 std::size_t&             ancestor,
                 std::size_t&             descendant) {
    color[u] = 1;
    for (const auto& cmd : states[u].commands) {
        // Only goto/do_goto are forward tree-edges. pop/do_pop are the return
        // path; swap/do_swap replace the top frame (pop-then-push) and are
        // inherently cyclic — all exempt from the acyclicity check.
        if (cmd.kind != EdgeKind::Goto && cmd.kind != EdgeKind::DoGoto) continue;
        auto it = std::ranges::find_if(states, [&](const State& s){
            return s.name == cmd.target && s.prompt.has_value();
        });
        if (it == states.end()) continue;             // unknown/abstract; validated earlier
        auto v = static_cast<std::size_t>(it - states.begin());
        switch (color[v]) {
        case 0:
            parent[v] = u;
            Engine::dfs_(states, v, color, parent, found, ancestor, descendant);
            if (found) return;
            break;
        case 1:
            found      = true;
            ancestor   = v;
            descendant = u;
            return;
        default: break;   // 2 = black, already done
        }
    }
    color[u] = 2;
}

std::string Engine::build_cycle_message_(const std::vector<Engine::State>& states,
                                         std::size_t                     ancestor,
                                         std::size_t                     descendant,
                                         const std::vector<std::size_t>& parent) {
    // Walk parent[] up from descendant to ancestor; reverse; close with ancestor.
    std::vector<std::size_t> path;
    path.push_back(descendant);
    std::size_t cur = descendant;
    while (cur != ancestor) {
        cur = parent[cur];
        path.push_back(cur);
    }
    std::ranges::reverse(path);
    path.push_back(ancestor);                          // close

    std::string msg = "cmdgraph: cycle detected: " + states[path[0]].name;
    for (std::size_t i = 1; i < path.size(); ++i)
        msg += " -> " + states[path[i]].name;
    return msg;
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

    case EdgeKind::Swap: {
        // Replace the top frame: pop-then-push, empty context.
        std::size_t tidx = find_state_(cmd.target);
        stack_.pop_back();
        push_state(tidx, {});
        return RC::Transitioned;
    }

    case EdgeKind::DoSwap: {
        if (!cmd.proc) return RC::Ok;
        auto r = cmd.proc(args, ctx);
        if (r.errored) {
            if (r.errmsg) emit_error_(*r.errmsg);
            return RC::Error;
        }
        if (r.value && !r.value->empty()) {
            // Non-empty return replaces the top frame with that value as context.
            std::size_t tidx = find_state_(cmd.target);
            stack_.pop_back();
            push_state(tidx, *r.value);
            return RC::Transitioned;
        }
        return RC::Ok;
    }

    case EdgeKind::Quit:
        stack_.clear();
        return RC::Exited;
    }
    return RC::Ok;  // unreachable
}

//──── Construction ───────────────────────────────────────────────────────────

void Engine::add_state(const std::string& name, const std::optional<std::string>& prompt) {
    if (finalized_)
        throw std::runtime_error("cmdgraph: add_state after finalize");
    if (find_state_(name) != std::string::npos)
        throw std::runtime_error("cmdgraph: state '" + name + "' already exists");
    State s;
    s.name   = name;
    s.prompt = prompt;
    states_.push_back(std::move(s));
}

void Engine::add_command(const std::string& state_name, const std::string& spec,
                          EdgeKind kind, const CommandOptions& opts) {
    if (finalized_)
        throw std::runtime_error("cmdgraph: add_command after finalize");
    std::size_t idx = find_state_(state_name);
    if (idx == std::string::npos)
        throw std::runtime_error("cmdgraph: unknown state '" + state_name + "'");

    for (std::size_t i = 0; i + 1 < opts.args.size(); ++i)
        if (opts.args[i].kind == ARG_REST)
            throw std::runtime_error(
                "cmdgraph: ARG_REST must be the last spec (command '" + spec + "')");

    // Construction-time validation: each edge kind has required slots; reject
    // missing values up-front rather than failing silently at runtime.
    // Canonical wording (matches Fortran die_missing and Tcl parse_edge):
    //   cmdgraph: <kind> edge '<spec>' missing required <proc|target>
    switch (kind) {
        case EdgeKind::Action:
            if (!opts.proc)
                throw std::runtime_error(
                    "cmdgraph: action edge '" + spec + "' missing required proc");
            break;
        case EdgeKind::Goto:
            if (opts.target.empty())
                throw std::runtime_error(
                    "cmdgraph: goto edge '" + spec + "' missing required target");
            break;
        case EdgeKind::Swap:
            if (opts.target.empty())
                throw std::runtime_error(
                    "cmdgraph: swap edge '" + spec + "' missing required target");
            break;
        case EdgeKind::DoGoto:
            if (opts.target.empty())
                throw std::runtime_error(
                    "cmdgraph: do_goto edge '" + spec + "' missing required target");
            if (!opts.proc)
                throw std::runtime_error(
                    "cmdgraph: do_goto edge '" + spec + "' missing required proc");
            break;
        case EdgeKind::DoSwap:
            if (opts.target.empty())
                throw std::runtime_error(
                    "cmdgraph: do_swap edge '" + spec + "' missing required target");
            if (!opts.proc)
                throw std::runtime_error(
                    "cmdgraph: do_swap edge '" + spec + "' missing required proc");
            break;
        case EdgeKind::DoPop:
            if (!opts.proc)
                throw std::runtime_error(
                    "cmdgraph: do_pop edge '" + spec + "' missing required proc");
            break;
        case EdgeKind::Pop:
        case EdgeKind::Quit:
            break;
    }

    Command cmd;
    cmd.spec   = spec;
    parse_spec(spec, cmd.req, cmd.opt);
    cmd.kind   = kind;
    cmd.target = opts.target;
    cmd.proc   = opts.proc;
    cmd.help   = opts.help;
    cmd.args   = opts.args;
    states_[idx].own_cmds.push_back(std::move(cmd));
}

void Engine::add_include(const std::string& state_name, const std::string& included) {
    if (finalized_)
        throw std::runtime_error("cmdgraph: add_include after finalize");
    std::size_t idx = find_state_(state_name);
    if (idx == std::string::npos)
        throw std::runtime_error("cmdgraph: unknown state '" + state_name + "'");
    states_[idx].includes.push_back(included);
}

void Engine::set_on_enter(const std::string& state_name, const OnEnterFn& proc) {
    if (finalized_)
        throw std::runtime_error("cmdgraph: set_on_enter after finalize");
    std::size_t idx = find_state_(state_name);
    if (idx == std::string::npos)
        throw std::runtime_error("cmdgraph: unknown state '" + state_name + "'");
    states_[idx].on_enter = proc;
}

void Engine::finalize(const std::string& initial) {
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
            if (cmd.kind == EdgeKind::Goto || cmd.kind == EdgeKind::DoGoto ||
                cmd.kind == EdgeKind::Swap || cmd.kind == EdgeKind::DoSwap) {
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

    // DAG check on goto/do_goto edges between concrete states. Iterate every
    // concrete state as a DFS root so cycles in components unreachable from
    // the initial state are still caught — mirrors Fortran find_cycle and Tcl
    // detect_cycle (both loop over all states).
    std::vector<int>         color (states_.size(), 0);
    std::vector<std::size_t> parent(states_.size(), 0);
    bool        found      = false;
    std::size_t ancestor   = 0;
    std::size_t descendant = 0;
    for (std::size_t i = 0; i < states_.size(); ++i) {
        if (!states_[i].prompt) continue;              // skip abstract
        if (color[i] != 0)      continue;
        Engine::dfs_(states_, i, color, parent, found, ancestor, descendant);
        if (found) break;
    }
    if (found)
        throw std::runtime_error(
            Engine::build_cycle_message_(states_, ancestor, descendant, parent));

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

// First non-separator index ≥ i (or s.size() if none).
// Matches Tcl strip_leading_arg_space / Fortran strip_leading_arg_space.
[[nodiscard]] static std::size_t strip_leading_arg_space_(const std::string& s, std::size_t i) {
    while (i < s.size() && s[i] == ' ') ++i;
    return i;
}

// Index of the first separator (space) at or after i that is not inside a
// double-quoted span, or s.size() if none.  Matches Tcl/Fortran
// first_arg_separator (single-char ARG_DELIMITERS == " ").
[[nodiscard]] static std::size_t first_arg_separator_(const std::string& s, std::size_t i) {
    bool in_quote = false;
    for (; i < s.size(); ++i) {
        char c = s[i];
        if (c == '"') in_quote = !in_quote;
        else if (!in_quote && c == ' ') return i;
    }
    return s.size();
}

RC Engine::dispatch(const std::string& line) {
    if (!finalized_ || stack_.empty()) return RC::Exited;

    // Split first token Tcl/Fortran-style: raw substring up to the first
    // unquoted space.  No type inference, no quote stripping on the command
    // name itself — anything goes; the prefix matcher just won't find it.
    // (Previously C++ tokenised the first word and rejected numeric tokens
    // as "command name must be a word"; Tcl/Fortran accept the literal and
    // route via the unknown channel, which is the canonical contract.)
    std::size_t cmd_start = strip_leading_arg_space_(line, 0);
    if (cmd_start >= line.size()) return RC::Ok;

    std::size_t cmd_end = first_arg_separator_(line, cmd_start);
    std::string cmd_name = line.substr(cmd_start, cmd_end - cmd_start);
    std::size_t arg_off  = (cmd_end < line.size())
                         ? strip_leading_arg_space_(line, cmd_end + 1)
                         : line.size();

    const auto& cmds = states_[stack_.back().state_idx].commands;

    // Prefix matching first (Tcl pattern); built-in help/? is the fall-through
    // when no command matches.  A graph-defined help/? naturally wins because
    // the prefix matcher finds it as a real command.
    std::vector<const Command*> matches;
    for (const auto& c : cmds)
        if (Engine::cmd_matches_(c, cmd_name)) matches.push_back(&c);

    if (matches.empty()) {
        if (cmd_name == "help" || cmd_name == "?") {
            emit_help_(cmds);
            return RC::Ok;
        }
        // Route via the info channel — matches Tcl emit_info / Fortran emit_info
        // so last_message carries the diagnostic (parity contract).
        emit_info_("unknown: " + cmd_name);
        return RC::Unknown;
    }
    if (matches.size() > 1) {
        // Canonical wording (locked decision):
        //   ambiguous: <cmd> matches a, b
        std::string msg = "ambiguous: " + cmd_name + " matches ";
        for (std::size_t i = 0; i < matches.size(); ++i) {
            if (i) msg += ", ";
            msg += matches[i]->spec;
        }
        emit_info_(msg);
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

// Drive the engine from a script file.  Blank / `#`-comment lines are skipped
// (matches Tcl cmdgraph-1.0.tm:424-426 and Fortran cmdgraph_sm.f90:429-430).
// Echo defaults ON and goes through emit_info_ so last_message tracks the
// echoed prompt+line — same contract as the other two impls.  On a failing
// dispatch, errmsg is taken from last_error (Error) or last_message
// (Unknown / Ambiguous, which are info-channel events in the parity contract).
// Open-failure discriminator: ok==false && *out_line==0.
bool Engine::run_file(const std::string& path, bool echo,
                       RC* out_stat, int* out_line, std::string* out_errmsg) {
    if (out_stat)   *out_stat   = RC::Ok;
    if (out_line)   *out_line   = 0;
    if (out_errmsg) out_errmsg->clear();

    std::ifstream f(path);
    if (!f) {
        // Populate last_error silently — do NOT write to the error channel
        // (matches Tcl set_error / Fortran set_error; the channel is reserved
        // for events that occurred during dispatch, not for the harness call).
        last_error = "could not open script file: " + path;
        if (out_errmsg) *out_errmsg = last_error;
        return false;
    }

    std::string line;
    int lno = 0;
    while (is_running() && std::getline(f, line)) {
        ++lno;

        // Skip blank lines and #-comment lines (first non-space char is #).
        std::size_t first = line.find_first_not_of(" \t");
        if (first == std::string::npos) continue;
        if (line[first] == '#')         continue;

        if (echo) {
            const auto& st = states_[stack_.back().state_idx];
            emit_info_((st.prompt ? *st.prompt : std::string{}) + line);
        }

        RC rc = dispatch(line);
        if (rc == RC::Exited) break;
        if (rc != RC::Ok && rc != RC::Transitioned) {
            if (out_stat)   *out_stat = rc;
            if (out_line)   *out_line = lno;
            if (out_errmsg) *out_errmsg = (rc == RC::Error) ? last_error : last_message;
            return false;
        }
    }
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
