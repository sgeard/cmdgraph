// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Simon Geard
//
/// @file cmdgraph.hxx
/// @brief cmdgraph — state-graph driven command interpreter.
///
/// Build the graph with add_state / add_command / add_include / set_on_enter,
/// call finalize(), then dispatch() or run().  The graph is immutable after
/// finalize; all introspection results are safe to cache keyed by state name.
///
/// See README.md for full documentation and examples.

#pragma once

#include <functional>
#include <iosfwd>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace cmdgraph {

//──── Version ─────────────────────────────────────────────────────────────────

/// Library version — major and minor are synchronised across all implementations.
struct Version {
    int major = 0;  ///< Breaking API change
    int minor = 0;  ///< Backwards-compatible feature addition
    int patch = 0;  ///< Bug fix
    /// @return Dot-separated version string, e.g. "1.1.0".
    [[nodiscard]] std::string string() const {
        return std::to_string(major) + '.' + std::to_string(minor) + '.' + std::to_string(patch);
    }
};

/// Compile-time library version constant.
inline constexpr Version CMDGRAPH_VERSION{1, 1, 0};

//──── Arg spec kinds ──────────────────────────────────────────────────────────

constexpr int ARG_INT  = 1;  ///< Integer token
constexpr int ARG_REAL = 2;  ///< Floating-point token (accepts d/D Fortran-style exponent)
constexpr int ARG_CHAR = 3;  ///< Word or double-quoted string (quotes stripped)
constexpr int ARG_REST = 4;  ///< Verbatim remainder of line — must be the last spec

/// Declarative argument specification attached to a command.
struct ArgSpec {
    std::string name;               ///< Displayed in help: @c \<name:kind\> or @c [name:kind]
    int         kind     = ARG_CHAR;
    bool        optional = false;   ///< Trailing optionals may be omitted; positional only
};

/// @name Arg spec constructors
/// Preferred over direct ArgSpec initialisation.
/// @{
[[nodiscard]] ArgSpec              arg_is_int (const std::string& name, bool optional = false);
[[nodiscard]] ArgSpec              arg_is_real(const std::string& name, bool optional = false);
[[nodiscard]] ArgSpec              arg_is_char(const std::string& name, bool optional = false);
[[nodiscard]] ArgSpec              arg_is_rest(const std::string& name, bool optional = false);
/// @brief Return @p n copies of an integer spec (fixed-size tuple, e.g. a 2D point).
[[nodiscard]] std::vector<ArgSpec> arg_int_n  (const std::string& name, int n);
/// @brief Return @p n copies of a real spec.
[[nodiscard]] std::vector<ArgSpec> arg_real_n (const std::string& name, int n);
/// @}

//──── Arg values ──────────────────────────────────────────────────────────────

/// Typed union of a parsed argument value.
using ArgValue = std::variant<int, double, std::string>;
/// Ordered list of parsed arguments passed to an action proc.
using ArgList  = std::vector<ArgValue>;

/// @name Arg value accessors
/// Call the accessor matching the spec kind; throws std::bad_variant_access on mismatch.
/// @{
[[nodiscard]] inline int         arg_int (const ArgValue& v) { return std::get<int>(v); }
[[nodiscard]] inline double      arg_real(const ArgValue& v) { return std::get<double>(v); }
[[nodiscard]] inline std::string arg_str (const ArgValue& v) { return std::get<std::string>(v); }
/// @}

//──── Action result ───────────────────────────────────────────────────────────

/// Return value from an action proc.  Use action_ok() / action_error() rather than
/// direct initialisation.
struct [[nodiscard]] ActionResult {
    bool                       errored = false;  ///< Set true to report an error
    std::optional<std::string> value;   ///< DoGoto context; nullopt or "" → no transition
    std::optional<std::string> errmsg;  ///< Message written to error channel when errored
};

/// @brief Successful result, optionally carrying a DoGoto context string.
ActionResult action_ok   (const std::optional<std::string>& ctx = std::nullopt);
/// @brief Error result, optionally with a message written to the error channel.
ActionResult action_error(const std::optional<std::string>& msg = std::nullopt);

//──── Function types ──────────────────────────────────────────────────────────

/// Signature of an action or gate procedure.
/// @param args  Parsed, validated argument list.
/// @param ctx   Context string of the current state (set by the preceding DoGoto).
using ActionFn  = std::function<ActionResult(const ArgList&, const std::string&)>;

/// Signature of an on_enter hook.  Called after every successful state transition.
/// @param ctx  Context string of the newly entered state.
using OnEnterFn = std::function<void(const std::string&)>;

//──── Edge kinds ──────────────────────────────────────────────────────────────

/// Controls what the engine does when a command is matched.
enum class EdgeKind {
    Action,  ///< Invoke proc; stay in current state
    Goto,    ///< Push target state with empty context (no proc)
    DoGoto,  ///< Invoke proc; non-empty return value pushes target with that value as context
    Pop,     ///< Pop the stack — the canonical back/esc path (no proc)
    DoPop,   ///< Invoke proc, then pop on success (commit-and-return)
    Quit     ///< Exit the engine
};

//──── Dispatch return codes ───────────────────────────────────────────────────

/// Return code from Engine::dispatch().  Callers that only drive a REPL may ignore it;
/// GUI and programmatic callers use it to update state indicators.
enum class [[nodiscard]] RC {
    Ok,           ///< Action ran, DoGoto stayed, built-in help shown, or blank line
    Unknown,      ///< No command matched the input
    Ambiguous,    ///< Multiple commands matched — input was a common prefix
    Transitioned, ///< State changed: Goto pushed, DoGoto succeeded, or Pop returned
    Exited,       ///< Engine stopped: Quit, stack exhausted, or already dead
    Error         ///< Action returned an error, or arg validation failed
};

//──── Introspection ───────────────────────────────────────────────────────────

/// Read-only description of one command in the current state, returned by
/// Engine::available_commands().
struct CommandInfo {
    std::string          spec;    ///< Full spec string, e.g. "p(airs)"
    std::string          req;     ///< Required prefix, e.g. "p"
    std::string          opt;     ///< Optional suffix, e.g. "airs"
    EdgeKind             kind = EdgeKind::Action;
    std::string          target;  ///< Destination state for Goto / DoGoto
    std::vector<ArgSpec> args;
    std::string          help;
};

//──── Engine ──────────────────────────────────────────────────────────────────

/// Options for a single command edge.  Designated-initialisers are recommended:
/// @code
///   eng.add_command("root", "q(uit)", EdgeKind::Quit, {.help = "exit"});
/// @endcode
struct CommandOptions {
    std::string          target = {};       ///< Destination state (Goto / DoGoto)
    ActionFn             proc   = nullptr;  ///< Action / gate proc (Action, DoGoto, DoPop)
    std::string          help   = {};       ///< Shown by built-in help command
    std::vector<ArgSpec> args   = {};       ///< Validated before proc is called
};

/// @brief State-graph driven command interpreter.
///
/// Typical usage:
/// @code
///   cmdgraph::Engine eng;
///   eng.add_state("root", "> ");
///   eng.add_command("root", "q(uit)", cmdgraph::EdgeKind::Quit, {.help = "exit"});
///   eng.finalize("root");
///   eng.run();
/// @endcode
///
/// Engine is move-only.  Construct, populate, finalize, then run — in that order.
/// Calling dispatch() or run() before finalize() is undefined behaviour.
class Engine {
public:
     Engine();
    ~Engine() = default;
    Engine(Engine&&)                 = default;
    Engine& operator=(Engine&&)      = default;
    Engine(const Engine&)            = delete;
    Engine& operator=(const Engine&) = delete;

    /// @name Construction
    /// Call these before finalize().  Order of add_state / add_command calls
    /// within a state does not matter; finalize() resolves includes.
    /// @{

    /// @brief Add a concrete state (has a prompt) or abstract state (mix-in, no prompt).
    /// @param name    Unique state identifier.
    /// @param prompt  Displayed before each input line.  Omit for an abstract (include-only) state.
    void add_state   (const std::string& name,
                      const std::optional<std::string>& prompt = std::nullopt);

    /// @brief Add a command edge to @p state.
    /// @param state  Owning state name.
    /// @param spec   Command spec, e.g. "p(airs)" — required prefix + optional suffix.
    /// @param kind   Edge behaviour (Action, Goto, DoGoto, Pop, DoPop, Quit).
    /// @param opts   Target state, proc, help text, and arg specs.
    void add_command (const std::string& state, const std::string& spec, EdgeKind kind,
                      const CommandOptions& opts = {});

    /// @brief Merge all commands from abstract state @p included into @p state.
    /// State's own commands override included ones with the same spec.
    void add_include (const std::string& state, const std::string& included);

    /// @brief Register a hook called after every successful transition into @p state.
    void set_on_enter(const std::string& state, const OnEnterFn& proc);

    /// @brief Validate the graph and set the initial state.
    /// @param initial  Name of the starting state.
    /// @throws std::runtime_error if a cycle is detected in goto/do_goto edges,
    ///         or if any state reference is unresolved.
    void finalize    (const std::string& initial);
    /// @}

    /// @name Execution
    /// @{

    /// @brief Run an interactive loop reading from the configured input stream.
    void                     run    ();

    /// @brief Execute commands from @p path, stopping at the first error.
    /// Blank lines and lines whose first non-whitespace character is @c # are
    /// skipped (not echoed, not dispatched, no line-number consumed for matching
    /// purposes — they still advance the 1-based counter).
    /// @param echo        If true, emit each prompt+line as it is read.
    ///                    Echo goes through the info channel, so #last_message
    ///                    reflects the most recently echoed line.
    /// @param out_stat    If non-null, receives the RC of the failing dispatch
    ///                    (or RC::Ok on success / open failure).
    /// @param out_line    If non-null, receives the 1-based line number of the
    ///                    failure (0 for a file-open failure or a successful run).
    /// @param out_errmsg  If non-null, receives the diagnostic text (mirrors
    ///                    #last_error for Error / dispatch failures and
    ///                    #last_message for Unknown / Ambiguous).
    /// @return True if the file ran to completion (or ended with quit); false otherwise.
    /// Open-failure discriminator: ok==false && *out_line==0.
    [[nodiscard]] bool        run_file(const std::string& path, bool echo = true,
                                       RC* out_stat = nullptr, int* out_line = nullptr,
                                       std::string* out_errmsg = nullptr);

    /// @brief Rewind to the initial state without rebuilding the graph.
    /// Clears the stack, contexts, last_message, and last_error.
    void                     reset  ();

    /// @brief Dispatch one line of input.
    /// Performs prefix matching, arg validation, and edge traversal.
    RC                       dispatch(const std::string& line);

    /// @brief Redirect I/O channels.  Pass nullptr to suppress a channel.
    /// Default: stdin / stdout / stderr.
    void set_io(std::istream* in  = nullptr,
                std::ostream* out = nullptr,
                std::ostream* err = nullptr);
    /// @}

    /// @name Inspection
    /// Safe to call from action procs and on_enter hooks.
    /// @{
    [[nodiscard]] std::string              current_state   () const;  ///< Name of the active state
    [[nodiscard]] std::string              current_context () const;  ///< Context of the active state
    [[nodiscard]] bool                     is_running      () const;  ///< False after Quit or stack exhausted
    /// @brief Commands visible in the current state (own + included, help/? excluded).
    /// Result depends only on the state name; safe to cache keyed by state name.
    [[nodiscard]] std::vector<CommandInfo> available_commands() const;
    /// @brief State names on the stack, bottom-first.
    [[nodiscard]] std::vector<std::string> state_path      () const;
    /// @}

    std::string last_message;  ///< Last info/prompt string written to the output channel
    std::string last_error;    ///< Last error string written to the error channel

private:
    // ── Internal types ──────────────────────────────────────────────────────

    struct Command {
        std::string          spec;
        std::string          req;
        std::string          opt;
        EdgeKind             kind   = EdgeKind::Action;
        std::string          target;
        ActionFn             proc   = nullptr;
        std::string          help;
        std::vector<ArgSpec> args;
    };

    struct State {
        std::string              name;
        std::optional<std::string> prompt;    // nullopt = abstract state
        OnEnterFn                on_enter  = nullptr;
        std::vector<std::string> includes;
        std::vector<Command>     own_cmds;  // as added, pre-finalize
        std::vector<Command>     commands;  // resolved after finalize
    };

    struct StackEntry {
        std::size_t state_idx = 0;
        std::string context;
    };

    // ── Data ────────────────────────────────────────────────────────────────

    std::vector<State>      states_;
    std::vector<StackEntry> stack_;
    std::size_t             initial_state_idx_ = 0;
    bool                    finalized_ = false;
    std::istream*           in_  = nullptr;
    std::ostream*           out_ = nullptr;
    std::ostream*           err_ = nullptr;

    // ── Private helpers ─────────────────────────────────────────────────────

    [[nodiscard]] std::size_t find_state_(const std::string& name) const;
    void                      emit_info_ (const std::string& msg);
    void                      emit_error_(const std::string& msg);
    void                      emit_help_ (const std::vector<Command>& cmds);
    [[nodiscard]] RC          apply_edge_(const Command& cmd, const ArgList& args);

    [[nodiscard]] static std::string cmd_usage_  (const Command& c);
    [[nodiscard]] static bool        cmd_matches_(const Command& c, const std::string& input);

    // DFS cycle detection over goto/do_goto edges between concrete states.
    // On a back-edge, sets found=true, ancestor=back-edge target, descendant=u,
    // and unwinds. Mirrors Fortran find_cycle/dfs (cmdgraph_sm.f90:1245-1299).
                  static void        dfs_        (const std::vector<State>& states,
                                                  std::size_t u,
                                                  std::vector<int>&         color,
                                                  std::vector<std::size_t>& parent,
                                                  bool&                     found,
                                                  std::size_t&              ancestor,
                                                  std::size_t&              descendant);

    // Build "cmdgraph: cycle detected: A -> B -> ... -> A" by walking parent[]
    // up from descendant to ancestor and reversing. Mirrors Fortran
    // build_cycle_message (cmdgraph_sm.f90:1303).
    [[nodiscard]] static std::string build_cycle_message_(
                                                  const std::vector<State>&       states,
                                                  std::size_t                     ancestor,
                                                  std::size_t                     descendant,
                                                  const std::vector<std::size_t>& parent);
};

} // namespace cmdgraph
