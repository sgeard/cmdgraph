.PHONY: all clean veryclean distclean utest coverage coverage-gcov coverage-clean perf help
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

# --- Module dependencies (auto-generated) ---
depends.mk: fortran_deps.tcl $(addprefix $(SRC_DIR)/,$(LIB_SRC)) $(TEST_SRC) $(APP_SRC) $(EX_SRC)
	tclsh $< $(SRC_DIR) $@ $(LIB_SRC) $(notdir $(TEST_SRC)) $(notdir $(APP_SRC)) $(notdir $(EX_SRC))

-include depends.mk

# --- Compilation rules ---
# Grouped targets (&:): each module .f90 produces both .o and .mod in one step.

$(ODIR)/dlist.o $(ODIR)/dlist.mod &: $(SRC_DIR)/dlist.f90 | $(ODIR)
	$(F) -c $(F_OPTS) -o $(ODIR)/dlist.o $<
	@touch $(ODIR)/dlist.mod

$(ODIR)/dlist_sm.o: $(SRC_DIR)/dlist_sm.f90 $(ODIR)/dlist.mod | $(ODIR)
	$(F) -c $(F_OPTS) -o $@ $<

$(ODIR)/cmdgraph.o $(ODIR)/cmdgraph.mod &: $(SRC_DIR)/cmdgraph.f90 $(ODIR)/dlist.mod | $(ODIR)
	$(F) -c $(F_OPTS) -o $(ODIR)/cmdgraph.o $<
	@touch $(ODIR)/cmdgraph.mod

$(ODIR)/cmdgraph_sm.o: $(SRC_DIR)/cmdgraph_sm.f90 $(ODIR)/cmdgraph.mod $(ODIR)/dlist.mod | $(ODIR)
	$(F) -c $(F_OPTS) -o $@ $<

# Library archive
$(LIB): $(LIB_OBJ) | $(ODIR)
	$(AR) rcs $@ $(LIB_OBJ)

# Tests
$(ODIR)/utest_%$(EXT): $(TEST_DIR)/utest_%.f90 $(LIB) | $(ODIR)
	$(F) $(F_OPTS) -o $@ $< $(LIB) $(LFLAGS)

# Demo app
$(ODIR)/main$(EXT): $(APP_DIR)/main.f90 $(LIB) | $(ODIR)
	$(F) $(F_OPTS) -o $@ $< $(LIB) $(LFLAGS)

# Example
$(ODIR)/cad_2d$(EXT): $(EX_DIR)/cad_2d.f90 $(LIB) | $(ODIR)
	$(F) $(F_OPTS) -o $@ $< $(LIB) $(LFLAGS)

$(ODIR):
	mkdir -p $@

utest: $(TEST_BIN)
	@for t in $(TEST_BIN); do echo "==> $$t" && $$t || exit 1; done

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
	@rm -vf $(ODIR)/*.o $(ODIR)/*.mod $(ODIR)/*.smod $(ODIR)/*.gcda $(ODIR)/*.gcno $(LIB) $(TEST_BIN) $(APP_BIN) $(EX_BIN) depends.mk $(OPTIONS_FNAME) *~ *.mod *.smod *.gcov

veryclean: clean
	@rm -vfr obj_* *.gcov

distclean: veryclean
	@rm -vrf depends.mk foptions_*.mk *~ $(PERF_DIR) build

help:
	@echo "Targets : all, utest, clean, veryclean, distclean"
	@echo "          coverage, coverage-gcov, coverage-clean"
	@echo "Options : F=gfortran|ifx|lfortran|flang (default ifx)  debug=1"
	@echo "LIB_SRC = $(LIB_SRC)"
	@echo "LIB_OBJ = $(LIB_OBJ)"
	@echo "TEST_BIN= $(TEST_BIN)"
	@echo "APP_BIN = $(APP_BIN)"
	@echo "ODIR    = $(ODIR)"
	@echo "F_OPTS  = $(F_OPTS)"
