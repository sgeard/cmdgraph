.PHONY: all clean veryclean distclean utest perf help
.SUFFIXES:
.DEFAULT_GOAL := all

# Compiler: CXX=icpx (default) or CXX=g++
CXX     ?= icpx
STD     := -std=c++23
WARN    := -Wall -Wextra -Wpedantic
OPT     := -O3
ODIR    := obj_$(CXX)

CXXFLAGS := $(STD) $(WARN) $(OPT) -Iinclude

LIB_SRC  := src/cmdgraph.cxx
LIB_OBJ  := $(ODIR)/cmdgraph.o
LIB      := $(ODIR)/libcmdgraph.a
PERF_DIR := perf

TEST_SRC := test/utest_cmdgraph.cxx
TEST_BIN := $(ODIR)/utest_cmdgraph

APP_SRC  := app/main.cxx
APP_BIN  := $(ODIR)/library_demo

CAD_SRC  := cad_2d/cad_2d.cxx
CAD_BIN  := $(ODIR)/cad_2d

$(ODIR):
	mkdir -p $(ODIR)

$(LIB_OBJ): $(LIB_SRC) include/cmdgraph.hxx | $(ODIR)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(LIB): $(LIB_OBJ) | $(ODIR)
	ar rcs $@ $^

$(TEST_BIN): $(TEST_SRC) $(LIB) | $(ODIR)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LIB)

$(APP_BIN): $(APP_SRC) $(LIB) | $(ODIR)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LIB)

$(CAD_BIN): $(CAD_SRC) $(LIB) | $(ODIR)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LIB)

all: $(LIB) $(TEST_BIN) $(APP_BIN) $(CAD_BIN)

utest: $(TEST_BIN)
	$(TEST_BIN)

perf: $(LIB)
	$(CXX) $(CXXFLAGS) -o $(ODIR)/perf_pathological $(PERF_DIR)/perf_pathological.cxx $(LIB)
	$(ODIR)/perf_pathological

clean:
	rm -f $(ODIR)/*.o $(ODIR)/*.a $(ODIR)/*.gcda $(ODIR)/*.gcno *.gcov

veryclean: clean
	rm -f $(TEST_BIN) $(APP_BIN) $(CAD_BIN)

distclean:
	rm -rf obj_icpx obj_g++  $(PERF_DIR)

help:
	@echo "make [CXX=icpx|g++]  build library, tests and demos"
	@echo "make utest            build and run unit tests"
	@echo "make veryclean        remove binaries"
	@echo "make distclean        remove all build output"
