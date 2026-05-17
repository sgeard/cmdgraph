// perf_pathological.cxx — demonstrates the two scaling bottlenecks
//
// Construction: add_command appends to an internal std::vector<Command>
// which grows via the standard capacity-doubling strategy; finalize copies
// to the resolved commands vector in O(N) total.
//
// Dispatch: find_matches must scan the entire command list of the current state
// to detect ambiguity.  Every dispatch is therefore O(N) regardless of which
// command was typed.
//
// For interactive use these costs are immaterial — graphs have tens of commands
// per state and dispatch happens at human speed.  This program makes them
// visible by scaling N to the point where the time becomes measurable, then
// shows the same workload on a realistic-sized graph.
//
// Build and run:  make -C .. CXX=icpx perf
//            or:  make -C .. CXX=g++  perf

#include "cmdgraph.hxx"
#include <cstdio>
#include <cstring>
#include <time.h>

static cmdgraph::ActionResult act_noop(const cmdgraph::ArgList&, const std::string&)
{
    return cmdgraph::action_ok();
}

static void build_engine(cmdgraph::Engine& eng, int n)
{
    eng = cmdgraph::Engine{};
    eng.add_state("root", "> ");
    char spec[8];
    for (int i = 1; i <= n; ++i) {
        std::snprintf(spec, sizeof(spec), "c%05d", i);
        eng.add_command("root", spec, cmdgraph::EdgeKind::Action,
                        {.proc = act_noop});
    }
    eng.finalize("root");
    eng.set_io(nullptr, nullptr, nullptr);
}

static double elapsed_s(const struct timespec& a, const struct timespec& b)
{
    return (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) * 1e-9;
}

static std::string itoa(int n)
{
    char buf[24];
    std::snprintf(buf, sizeof(buf), "%d", n);
    return buf;
}

int main()
{
    constexpr int N_BIG   = 5000;
    constexpr int N_SMALL = 20;
    constexpr int D       = 100000;

    cmdgraph::Engine eng;
    struct timespec t0, t1;

    std::printf("\n=== pathological case (N=%s) ===\n\n", itoa(N_BIG).c_str());

    // -- Construction O(N) amortised --
    clock_gettime(CLOCK_MONOTONIC, &t0);
    build_engine(eng, N_BIG);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    std::printf("  construction (add_command x %s):  %7.3f s   [O(N) amortised]\n",
                itoa(N_BIG).c_str(), elapsed_s(t0, t1));

    // -- Dispatch O(N) per call --
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < D; ++i)
        (void)eng.dispatch("c00001");
    clock_gettime(CLOCK_MONOTONIC, &t1);
    std::printf("  dispatch x %s:                        %7.3f s   [O(N x D)]\n",
                itoa(D).c_str(), elapsed_s(t0, t1));

    std::printf("\n=== realistic case (N=%s) ===\n\n", itoa(N_SMALL).c_str());

    clock_gettime(CLOCK_MONOTONIC, &t0);
    build_engine(eng, N_SMALL);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    std::printf("  construction (add_command x %s):   %7.3f s\n",
                itoa(N_SMALL).c_str(), elapsed_s(t0, t1));

    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < D; ++i)
        (void)eng.dispatch("c00001");
    clock_gettime(CLOCK_MONOTONIC, &t1);
    std::printf("  dispatch x %s:                        %7.3f s\n",
                itoa(D).c_str(), elapsed_s(t0, t1));

    return 0;
}
