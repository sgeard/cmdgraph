.PHONY: all check depcheck clean veryclean distclean utest coverage coverage-gcov coverage-clean perf help
.SUFFIXES:
.DEFAULT_GOAL := all

# Source layout
SRC_DIR  := src
APP_DIR  := app
TEST_DIR := test
EX_DIR   := cad_2d
PERF_DIR := perf

# Per-compiler extras consumed by foptions_$(F).mk
F_EXTRA_GF  := -Wno-unused-dummy-argument
F_EXTRA_IFX := -diag-disable 7712

# --- Compiler selection: default ifx (release), validated ------------------
F ?= ifx
VALID_F := gfortran ifx lfortran flang
ifeq ($(filter $(F),$(VALID_F)),)
  $(error Unknown Fortran compiler 'F=$(F)' -- choose one of: $(VALID_F))
endif

# Canonical compiler options, generated into foptions_$(F).mk by generate_fopts.tcl
OPTIONS_FNAME := foptions_$(F).mk
$(OPTIONS_FNAME): generate_fopts.tcl
	tclsh generate_fopts.tcl $(F) $(OPTIONS_FNAME)

-include $(OPTIONS_FNAME)

F_OPTS := $(F_BASE) $(F_BUILD) $(MOD_OPTS) -I$(SRC_DIR)
LFLAGS := $(F_LOPTS)

# --- Sources ---
LIB_SRC := dlist.f90 dlist_sm.f90 cmdgraph.f90 cmdgraph_sm.f90
LIB_OBJ := $(addprefix $(ODIR)/,$(LIB_SRC:.f90=.o))
LIB     := $(ODIR)/libcmdgraph.a

# Test binaries: one per test/utest_*.f90
TEST_SRC := $(wildcard $(TEST_DIR)/utest_*.f90)
TEST_BIN := $(patsubst $(TEST_DIR)/%.f90,$(ODIR)/%$(EXT),$(TEST_SRC))

# Demo app (optional — only built if app/main.f90 exists)
APP_SRC := $(wildcard $(APP_DIR)/main.f90)
APP_BIN := $(patsubst $(APP_DIR)/%.f90,$(ODIR)/%$(EXT),$(APP_SRC))

# Example
EX_SRC  := $(wildcard $(EX_DIR)/cad_2d.f90)
EX_BIN  := $(patsubst $(EX_DIR)/%.f90,$(ODIR)/%$(EXT),$(EX_SRC))

all: $(OPTIONS_FNAME) $(LIB) $(TEST_BIN) $(APP_BIN) $(EX_BIN)

# --- Module dependencies: depends.mk, written by tf_bld.tcl ---
# The master in ../../common/tf_bld, run in place; a standalone copy of this
# project (no ../../common) carries its own tf_bld.tcl beside this Makefile.
# The Makefile names the sources: the library's and every program's. No entry
# points: every program links libcmdgraph.a.
TF_BLD  ?= $(firstword $(wildcard ../../common/tf_bld/tf_bld.tcl) tf_bld.tcl)
TF_SRCS := $(addprefix $(SRC_DIR)/,$(LIB_SRC)) $(TEST_SRC) $(APP_SRC) $(EX_SRC)

ifeq ($(filter clean veryclean distclean help depcheck coverage-clean,$(MAKECMDGOALS)),)
include depends.mk
endif

# Each TF_EXT_m hook (none here) would declare a sibling's module
TF_ARGS = $(TF_SRCS) \
    $(addprefix -ext ,$(patsubst TF_EXT_%,%,$(filter TF_EXT_%,$(.VARIABLES))))

# After the include: TF_SOURCES (every file the last scan read) comes from it
depends.mk: $(TF_BLD) Makefile $(TF_SRCS) $(TF_SOURCES)
	tclsh $(TF_BLD) -o $@ $(TF_ARGS)

# The same scan with warnings as errors: a forgotten source or an
# unimplemented separate procedure fails here, not at the link
depcheck:
	tclsh $(TF_BLD) -Werror -o depends.mk $(TF_ARGS)

# --- Compilation: one pattern rule; depends.mk supplies the prerequisites
# (and the vpath)
$(ODIR)/%.o: %.f90 | $(ODIR)
	$(F) -c $(F_OPTS) -o $@ $<

# Library archive
$(LIB): $(LIB_OBJ) | $(ODIR)
	$(AR) rcs $@ $(LIB_OBJ)

# Tests, demo app and example: each links its own object and the library
$(TEST_BIN) $(APP_BIN) $(EX_BIN): $(ODIR)/%$(EXT): $(ODIR)/%.o $(LIB)
	$(F) $(F_OPTS) -o $@ $< $(LIB) $(LFLAGS)

$(ODIR):
	mkdir -p $@

utest: $(TEST_BIN)
	@for t in $(TEST_BIN); do echo "==> $$t" && $$t || exit 1; done

check: depcheck utest

perf: $(LIB)
	$(F) $(F_OPTS) -o $(ODIR)/perf_pathological$(EXT) \
	    $(PERF_DIR)/perf_pathological.f90 $(LIB) $(LFLAGS)
	$(ODIR)/perf_pathological$(EXT)

coverage: coverage-gcov

coverage-gcov:
	@rm -vf *.gcov obj_gfortran_debug/*.gcda obj_gfortran_debug/*.gcno obj_gfortran_debug/*.o obj_gfortran_debug/*.mod obj_gfortran_debug/*.smod obj_gfortran_debug/libcmdgraph.a obj_gfortran_debug/utest_*_d
	$(MAKE) F=gfortran debug=1 F_EXTRA_GF='$(F_EXTRA_GF) --coverage' F_LOPTS_GF='$(F_LOPTS_GF) --coverage' utest
	@rm -vf *.gcov
	gcov -b -c -o obj_gfortran_debug $(addprefix $(SRC_DIR)/,$(LIB_SRC))

coverage-clean:
	@rm -vf *.gcov obj_gfortran_debug/*.gcda obj_gfortran_debug/*.gcno

clean:
	@rm -vf $(ODIR)/*.o $(ODIR)/*.mod $(ODIR)/*.smod $(ODIR)/*.gcda $(ODIR)/*.gcno $(LIB) $(TEST_BIN) $(APP_BIN) $(EX_BIN) $(OPTIONS_FNAME) *~ *.mod *.smod *.gcov

veryclean: clean
	@rm -vfr obj_* *.gcov

distclean: veryclean
	@rm -vrf depends.mk foptions_*.mk *~ $(PERF_DIR) build

help:
	@echo "Targets : all, utest, check (depcheck utest), depcheck, clean, veryclean, distclean"
	@echo "          coverage, coverage-gcov, coverage-clean"
	@echo "Options : F=gfortran|ifx|lfortran|flang (default ifx)  debug=1"
	@echo "LIB_SRC = $(LIB_SRC)"
	@echo "LIB_OBJ = $(LIB_OBJ)"
	@echo "TEST_BIN= $(TEST_BIN)"
	@echo "APP_BIN = $(APP_BIN)"
	@echo "ODIR    = $(ODIR)"
	@echo "F_OPTS  = $(F_OPTS)"
