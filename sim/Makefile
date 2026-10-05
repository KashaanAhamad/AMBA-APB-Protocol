# ==============================================================================
# Makefile: AMBA APB Protocol — Simulation & Synthesis Automation
# ==============================================================================
# Tool:     QuestaSim (ModelSim) for simulation, Xilinx Vivado for synthesis
# Usage:    make help          — show all available targets
#           make compile       — compile RTL + TB
#           make sim           — run single test (default: test_single_write)
#           make sim TEST=test_random_stress_1000 SEED=12345
#           make regression    — run all tests
#           make coverage      — merge and report coverage
#           make synth         — run Vivado synthesis
#           make clean         — remove all generated files
# ==============================================================================

# ==============================================================================
# Tool Configuration
# ==============================================================================
# QuestaSim / ModelSim binaries
# Update these paths in scripts/setup_env.sh or override on command line:
#   make compile VLOG=/opt/questasim/bin/vlog
# ==============================================================================
VLIB   ?= vlib
VLOG   ?= vlog
VSIM   ?= vsim
VCOVER ?= vcover
VOPT   ?= vopt

# Vivado
VIVADO ?= vivado

# Verilator (for linting — optional)
VERILATOR ?= verilator

# ==============================================================================
# Project Paths
# ==============================================================================
PROJECT_ROOT := $(shell cd .. && pwd)
RTL_DIR      := $(PROJECT_ROOT)/rtl
TB_DIR       := $(PROJECT_ROOT)/tb
SIM_DIR      := $(PROJECT_ROOT)/sim
SYNTH_DIR    := $(PROJECT_ROOT)/synth
SCRIPTS_DIR  := $(PROJECT_ROOT)/scripts

# ==============================================================================
# Simulation Configuration
# ==============================================================================
# TEST:       Test name (matches $test$plusargs in apb_tb_top.sv)
# SEED:       Random seed ("random" for auto-seed, or integer)
# VERBOSITY:  Log verbosity level
# TIMEOUT:    Simulation timeout in nanoseconds
# COV_EN:     Enable code + functional coverage (1/0)
# WAVE_EN:    Enable waveform dumping (1/0)
# GUI:        Run in GUI mode (1/0)
# ==============================================================================
TEST       ?= test_single_write
SEED       ?= random
VERBOSITY  ?= MEDIUM
TIMEOUT    ?= 10000000
COV_EN     ?= 1
WAVE_EN    ?= 0
GUI        ?= 0

# ==============================================================================
# Work Library
# ==============================================================================
WORK_LIB   := work
WORK_DIR   := $(SIM_DIR)/work

# ==============================================================================
# Results & Coverage Directories
# ==============================================================================
RESULTS_DIR := $(SIM_DIR)/results
COV_DIR     := $(SIM_DIR)/cov_html
COV_MERGED  := $(SIM_DIR)/merged.ucdb

# ==============================================================================
# RTL Source Files (compile order)
# ==============================================================================
RTL_FILES := \
    $(RTL_DIR)/apb_master_fsm.v \
    $(RTL_DIR)/apb_master.v \
    $(RTL_DIR)/apb_decoder.v \
    $(RTL_DIR)/apb_mux.v \
    $(RTL_DIR)/apb_slave.v \
    $(RTL_DIR)/apb_top.v

# ==============================================================================
# Testbench Source Files (compile order)
# ==============================================================================
# Note: Class-based files (transaction, driver, monitor, etc.) are `included
# by apb_tb_top.sv, so only the interface, assertions, and tb_top are compiled
# directly. The include path (+incdir) resolves the `include directives.
# ==============================================================================
TB_FILES := \
    $(TB_DIR)/apb_if.sv \
    $(TB_DIR)/apb_assertions.sv \
    $(TB_DIR)/apb_tb_top.sv

# ==============================================================================
# Compiler Flags
# ==============================================================================
VLOG_FLAGS := -sv \
              +incdir+$(RTL_DIR) \
              +incdir+$(TB_DIR) \
              -work $(WORK_LIB) \
              -lint

# Add coverage instrumentation if enabled
ifeq ($(COV_EN),1)
    VLOG_FLAGS += +cover=bcestf
endif

# ==============================================================================
# Simulator Flags
# ==============================================================================
# Seed handling
ifeq ($(SEED),random)
    SEED_FLAG := -sv_seed random
else
    SEED_FLAG := -sv_seed $(SEED)
endif

# Base simulator flags
VSIM_FLAGS := $(SEED_FLAG) \
              +$(TEST) \
              +TIMEOUT=$(TIMEOUT) \
              -t 1ps

# Coverage flags
ifeq ($(COV_EN),1)
    VSIM_FLAGS += -coverage
    VSIM_FLAGS += -coverstore $(RESULTS_DIR)/$(TEST).ucdb
endif

# Waveform flags
ifeq ($(WAVE_EN),1)
    VSIM_FLAGS += +WAVE_EN
    VSIM_FLAGS += -wlf $(RESULTS_DIR)/$(TEST).wlf
endif

# GUI vs batch mode
ifeq ($(GUI),1)
    VSIM_RUN := $(VSIM) $(VSIM_FLAGS) -do "do wave.do; run -all" $(WORK_LIB).apb_tb_top
else
    VSIM_RUN := $(VSIM) -batch $(VSIM_FLAGS) \
                -do "run -all; quit -f" \
                $(WORK_LIB).apb_tb_top
endif

# ==============================================================================
# Test List (for regression)
# ==============================================================================
TEST_LIST := \
    test_single_write \
    test_single_read \
    test_write_read_all_slaves \
    test_all_registers_slave0 \
    test_all_registers_slave1 \
    test_all_registers_slave2 \
    test_wait_state_timing \
    test_back_to_back_same_slave \
    test_back_to_back_diff_slave \
    test_b2b_write_read \
    test_b2b_read_read \
    test_b2b_read_write \
    test_unaligned_addr \
    test_invalid_addr_range \
    test_reset_during_idle \
    test_reset_during_transfer \
    test_reset_clears_registers \
    test_data_walking_ones \
    test_data_walking_zeros \
    test_data_all_ones_zeros \
    test_data_checkerboard \
    test_random_stress_100 \
    test_random_stress_1000 \
    test_slave2_burst_wait

# NOTE: test_random_stress_10000 excluded from default regression (too long).
#       Add it manually or use: make sim TEST=test_random_stress_10000

# ==============================================================================
# TARGETS
# ==============================================================================

# ------------------------------------------------------------------------------
# Default target
# ------------------------------------------------------------------------------
.PHONY: all
all: compile sim
	@echo "═══════════════════════════════════════════════════"
	@echo "  Default build + simulation complete."
	@echo "═══════════════════════════════════════════════════"

# ------------------------------------------------------------------------------
# help — Print usage information
# ------------------------------------------------------------------------------
.PHONY: help
help:
	@echo ""
	@echo "╔══════════════════════════════════════════════════════════════════╗"
	@echo "║        AMBA APB Protocol — Makefile Usage Guide                  ║"
	@echo "╠══════════════════════════════════════════════════════════════════╣"
	@echo "║                                                                  ║"
	@echo "║  Compilation:                                                    ║"
	@echo "║    make compile            Compile all RTL + TB files            ║"
	@echo "║                                                                  ║"
	@echo "║  Simulation:                                                     ║"
	@echo "║    make sim                Run default test (test_single_write)   ║"
	@echo "║    make sim TEST=<name>    Run a specific test                    ║"
	@echo "║    make sim SEED=12345     Run with specific random seed          ║"
	@echo "║    make sim GUI=1          Run in QuestaSim GUI mode              ║"
	@echo "║    make sim WAVE_EN=1      Enable waveform dumping                ║"
	@echo "║                                                                  ║"
	@echo "║  Regression:                                                     ║"
	@echo "║    make regression         Run ALL tests sequentially             ║"
	@echo "║                                                                  ║"
	@echo "║  Coverage:                                                       ║"
	@echo "║    make coverage           Merge UCDBs + generate HTML report     ║"
	@echo "║                                                                  ║"
	@echo "║  Synthesis:                                                      ║"
	@echo "║    make synth              Run Vivado synthesis (batch mode)      ║"
	@echo "║                                                                  ║"
	@echo "║  Linting:                                                        ║"
	@echo "║    make lint               Run Verilator lint check on RTL        ║"
	@echo "║                                                                  ║"
	@echo "║  Cleanup:                                                        ║"
	@echo "║    make clean              Remove all generated files             ║"
	@echo "║    make clean_results      Remove only simulation results         ║"
	@echo "║    make clean_work         Remove only work library               ║"
	@echo "║                                                                  ║"
	@echo "║  Variables:                                                      ║"
	@echo "║    TEST=<name>        Test name          (default: test_single_write)  ║"
	@echo "║    SEED=<int|random>  Random seed        (default: random)        ║"
	@echo "║    COV_EN=<0|1>       Coverage enable    (default: 1)             ║"
	@echo "║    WAVE_EN=<0|1>      Waveform enable    (default: 0)             ║"
	@echo "║    GUI=<0|1>          GUI mode enable    (default: 0)             ║"
	@echo "║    TIMEOUT=<ns>       Sim timeout in ns  (default: 10000000)      ║"
	@echo "║                                                                  ║"
	@echo "╚══════════════════════════════════════════════════════════════════╝"
	@echo ""

# ------------------------------------------------------------------------------
# compile — Compile all RTL and testbench sources
# ------------------------------------------------------------------------------
.PHONY: compile
compile: $(WORK_DIR)
	@echo ""
	@echo "──────────────────────────────────────────────────"
	@echo "  Compiling RTL files..."
	@echo "──────────────────────────────────────────────────"
	$(VLOG) $(VLOG_FLAGS) $(RTL_FILES)
	@echo ""
	@echo "──────────────────────────────────────────────────"
	@echo "  Compiling Testbench files..."
	@echo "──────────────────────────────────────────────────"
	$(VLOG) $(VLOG_FLAGS) $(TB_FILES)
	@echo ""
	@echo "  ✓ Compilation complete."
	@echo ""

# Create work library if it doesn't exist
$(WORK_DIR):
	@echo "  Creating work library: $(WORK_DIR)"
	$(VLIB) $(WORK_LIB)

# ------------------------------------------------------------------------------
# sim — Run a single simulation
# ------------------------------------------------------------------------------
.PHONY: sim
sim: compile | $(RESULTS_DIR)
	@echo ""
	@echo "══════════════════════════════════════════════════"
	@echo "  Running test: $(TEST)"
	@echo "  Seed: $(SEED)"
	@echo "  Coverage: $(COV_EN)  Waves: $(WAVE_EN)  GUI: $(GUI)"
	@echo "══════════════════════════════════════════════════"
	@echo ""
	$(VSIM_RUN) | tee $(RESULTS_DIR)/$(TEST).log
	@echo ""
	@echo "  ✓ Test $(TEST) complete."
	@echo "  Log: $(RESULTS_DIR)/$(TEST).log"
	@echo ""

# Create results directory
$(RESULTS_DIR):
	@mkdir -p $(RESULTS_DIR)

# ------------------------------------------------------------------------------
# regression — Run all tests sequentially
# ------------------------------------------------------------------------------
.PHONY: regression
regression: compile | $(RESULTS_DIR)
	@echo ""
	@echo "╔══════════════════════════════════════════════════╗"
	@echo "║         Starting Full Regression                  ║"
	@echo "║         Tests: $(words $(TEST_LIST))                                  ║"
	@echo "╚══════════════════════════════════════════════════╝"
	@echo ""
	@PASS=0; FAIL=0; TOTAL=0; \
	for test in $(TEST_LIST); do \
		TOTAL=$$((TOTAL + 1)); \
		echo ""; \
		echo "────────────────────────────────────────────────"; \
		echo "  [$$TOTAL/$(words $(TEST_LIST))] Running: $$test"; \
		echo "────────────────────────────────────────────────"; \
		$(VSIM) -batch $(SEED_FLAG) \
			+$$test \
			+TIMEOUT=$(TIMEOUT) \
			-t 1ps \
			$(if $(filter 1,$(COV_EN)),-coverage -coverstore $(RESULTS_DIR)/$$test.ucdb) \
			-do "run -all; quit -f" \
			$(WORK_LIB).apb_tb_top \
			> $(RESULTS_DIR)/$$test.log 2>&1; \
		if [ $$? -eq 0 ] && grep -q "SIMULATION PASSED\|ALL CHECKS PASSED" $(RESULTS_DIR)/$$test.log; then \
			echo "  ✓ $$test: PASSED"; \
			PASS=$$((PASS + 1)); \
		else \
			echo "  ✗ $$test: FAILED"; \
			FAIL=$$((FAIL + 1)); \
		fi; \
	done; \
	echo ""; \
	echo "╔══════════════════════════════════════════════════╗"; \
	echo "║         Regression Summary                        ║"; \
	echo "╠══════════════════════════════════════════════════╣"; \
	echo "║  Total : $$TOTAL                                   ║"; \
	echo "║  Passed: $$PASS                                    ║"; \
	echo "║  Failed: $$FAIL                                    ║"; \
	echo "╚══════════════════════════════════════════════════╝"; \
	echo ""; \
	if [ $$FAIL -gt 0 ]; then exit 1; fi

# ------------------------------------------------------------------------------
# coverage — Merge UCDB files and generate HTML report
# ------------------------------------------------------------------------------
.PHONY: coverage
coverage:
	@echo ""
	@echo "──────────────────────────────────────────────────"
	@echo "  Merging coverage databases..."
	@echo "──────────────────────────────────────────────────"
	@if ls $(RESULTS_DIR)/*.ucdb 1>/dev/null 2>&1; then \
		$(VCOVER) merge $(COV_MERGED) $(RESULTS_DIR)/*.ucdb; \
		echo "  Merged into: $(COV_MERGED)"; \
		echo ""; \
		echo "──────────────────────────────────────────────────"; \
		echo "  Generating HTML coverage report..."; \
		echo "──────────────────────────────────────────────────"; \
		$(VCOVER) report -html -output $(COV_DIR) $(COV_MERGED); \
		echo "  Report: $(COV_DIR)/index.html"; \
		echo ""; \
		echo "──────────────────────────────────────────────────"; \
		echo "  Coverage Summary (text):"; \
		echo "──────────────────────────────────────────────────"; \
		$(VCOVER) report $(COV_MERGED); \
	else \
		echo "  ERROR: No .ucdb files found in $(RESULTS_DIR)/"; \
		echo "  Run 'make regression' or 'make sim COV_EN=1' first."; \
		exit 1; \
	fi
	@echo ""

# ------------------------------------------------------------------------------
# lint — Run Verilator lint check on RTL
# ------------------------------------------------------------------------------
.PHONY: lint
lint:
	@echo ""
	@echo "──────────────────────────────────────────────────"
	@echo "  Running Verilator lint check..."
	@echo "──────────────────────────────────────────────────"
	$(VERILATOR) --lint-only \
		-Wall \
		+incdir+$(RTL_DIR) \
		$(RTL_FILES) \
		2>&1 | tee $(SIM_DIR)/lint_report.txt
	@echo ""
	@echo "  ✓ Lint check complete. Report: $(SIM_DIR)/lint_report.txt"
	@echo ""

# ------------------------------------------------------------------------------
# synth — Run Vivado synthesis in batch mode
# ------------------------------------------------------------------------------
.PHONY: synth
synth:
	@echo ""
	@echo "──────────────────────────────────────────────────"
	@echo "  Running Vivado synthesis..."
	@echo "──────────────────────────────────────────────────"
	@mkdir -p $(SYNTH_DIR)/reports
	cd $(SYNTH_DIR) && $(VIVADO) -mode batch \
		-source synth.tcl \
		-log reports/synth.log \
		-journal reports/synth.jou
	@echo ""
	@echo "  ✓ Synthesis complete. Reports: $(SYNTH_DIR)/reports/"
	@echo ""

# ------------------------------------------------------------------------------
# wave — Open QuestaSim GUI with waveform from last simulation
# ------------------------------------------------------------------------------
.PHONY: wave
wave:
	@echo "  Opening QuestaSim GUI..."
	@if [ -f $(RESULTS_DIR)/$(TEST).wlf ]; then \
		$(VSIM) -view $(RESULTS_DIR)/$(TEST).wlf -do wave.do; \
	else \
		echo "  ERROR: No waveform file found: $(RESULTS_DIR)/$(TEST).wlf"; \
		echo "  Run 'make sim TEST=$(TEST) WAVE_EN=1' first."; \
	fi

# ------------------------------------------------------------------------------
# clean — Remove all generated files
# ------------------------------------------------------------------------------
.PHONY: clean
clean: clean_work clean_results clean_coverage
	@rm -f $(SIM_DIR)/transcript
	@rm -f $(SIM_DIR)/vsim.wlf
	@rm -f $(SIM_DIR)/lint_report.txt
	@rm -f $(SIM_DIR)/*.vcd
	@rm -f $(SIM_DIR)/modelsim.ini
	@rm -rf $(SYNTH_DIR)/reports
	@rm -rf $(SYNTH_DIR)/.Xil
	@echo "  ✓ All generated files cleaned."

.PHONY: clean_work
clean_work:
	@echo "  Removing work library..."
	@rm -rf $(WORK_DIR)

.PHONY: clean_results
clean_results:
	@echo "  Removing simulation results..."
	@rm -rf $(RESULTS_DIR)

.PHONY: clean_coverage
clean_coverage:
	@echo "  Removing coverage data..."
	@rm -rf $(COV_DIR)
	@rm -f $(COV_MERGED)

# ==============================================================================
# Convenience aliases
# ==============================================================================
.PHONY: comp run regress cov
comp:    compile
run:     sim
regress: regression
cov:     coverage

