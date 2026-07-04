# Build the Fortran and C++ parity runners against the in-tree libraries.
# Secondary compilers by default (no special env): override with
#   make F=ifx CXX=icpx
.PHONY: all fortran cpp clean veryclean
.DEFAULT_GOAL := all

F   ?= gfortran
CXX ?= g++

ROOT     := ../..
FDIR     := $(ROOT)/fortran
CDIR     := $(ROOT)/cpp

# Mirror generate_fopts.tcl / cpp Makefile ODIR conventions (release build).
ifeq ($(F),gfortran)
  FODIR := obj_gfortran_release
else ifeq ($(F),ifx)
  FODIR := obj_intel_release
else
  FODIR := obj_$(F)_release
endif
CODIR := obj_$(CXX)

BIN := bin
all: fortran cpp

$(BIN):
	mkdir -p $(BIN)

# --- Fortran runner ---
fortran: | $(BIN)
	$(MAKE) -C $(FDIR) F=$(F)
	$(F) -cpp -J$(BIN) -I$(FDIR)/$(FODIR) -o $(BIN)/runner_f runner.f90 \
	    $(FDIR)/$(FODIR)/libcmdgraph.a -Wl,-z,execstack

# --- C++ runner ---
cpp: | $(BIN)
	$(MAKE) -C $(CDIR) CXX=$(CXX) $(CODIR)/libcmdgraph.a
	$(CXX) -std=c++23 -O2 -I$(CDIR)/include -o $(BIN)/runner_cpp runner.cxx \
	    $(CDIR)/$(CODIR)/libcmdgraph.a

clean:
	@rm -rvf $(BIN)
	@rm -fv *.mod *.smod

veryclean: clean
	@rm -rvf .work

