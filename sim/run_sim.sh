#!/bin/bash
# ==============================================================================
# Script:  run_sim.sh
# Purpose: Run a single APB simulation with QuestaSim.
#
#          Wrapper around vsim invocation with full argument parsing,
#          timestamped log management, and clear PASS/FAIL exit reporting.
#
# Usage:
#   ./run_sim.sh                                        # Default test
#   ./run_sim.sh --test test_single_write               # Specific test
#   ./run_sim.sh --test test_random_stress_1000 --seed 42
#   ./run_sim.sh --test test_single_read --waves --coverage
#   ./run_sim.sh --test test_all_registers_slave0 --gui
#   ./run_sim.sh --help
#
# Exit Codes:
#   0 — Simulation PASSED
#   1 — Simulation FAILED (assertion failure or scoreboard mismatch)
#   2 — Compilation error
#   3 — Invalid arguments
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Default Configuration
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SIM_DIR="${SCRIPT_DIR}"
RTL_DIR="${PROJECT_ROOT}/rtl"
TB_DIR="${PROJECT_ROOT}/tb"

# Tool binaries (override via environment or setup_env.sh)
VLIB="${VLIB:-vlib}"
VLOG="${VLOG:-vlog}"
VSIM="${VSIM:-vsim}"

# Simulation parameters
TEST="test_single_write"
SEED="random"
TIMEOUT="10000000"
COVERAGE=0
WAVES=0
GUI=0
COMPILE_ONLY=0
SKIP_COMPILE=0
VERBOSITY="MEDIUM"

# ==============================================================================
# Color Output Helpers
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'  # No Color

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[PASS]${NC} $*"; }
error()   { echo -e "${RED}[FAIL]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ==============================================================================
# Usage / Help
# ==============================================================================
print_usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} $(basename "$0") [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --test <name>      Test name (default: test_single_write)"
    echo "  --seed <int|random> Random seed (default: random)"
    echo "  --timeout <ns>     Simulation timeout in ns (default: 10000000)"
    echo "  --coverage         Enable code + functional coverage"
    echo "  --waves            Enable waveform dumping (VCD + WLF)"
    echo "  --gui              Run in QuestaSim GUI mode"
    echo "  --compile-only     Compile only, don't simulate"
    echo "  --skip-compile     Skip compilation (use existing work library)"
    echo "  --verbosity <LVL>  Log verbosity: LOW, MEDIUM, HIGH, DEBUG"
    echo "  --help             Show this help message"
    echo ""
    echo "Available tests:"
    echo "  test_single_write          test_single_read"
    echo "  test_write_read_all_slaves test_all_registers_slave0"
    echo "  test_all_registers_slave1  test_all_registers_slave2"
    echo "  test_wait_state_timing     test_back_to_back_same_slave"
    echo "  test_back_to_back_diff_slave test_b2b_write_read"
    echo "  test_b2b_read_read         test_b2b_read_write"
    echo "  test_unaligned_addr        test_invalid_addr_range"
    echo "  test_reset_during_idle     test_reset_during_transfer"
    echo "  test_reset_clears_registers test_data_walking_ones"
    echo "  test_data_walking_zeros    test_data_all_ones_zeros"
    echo "  test_data_checkerboard     test_random_stress_100"
    echo "  test_random_stress_1000    test_random_stress_10000"
    echo "  test_slave2_burst_wait"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") --test test_single_write --coverage --waves"
    echo "  $(basename "$0") --test test_random_stress_1000 --seed 12345"
    echo "  $(basename "$0") --test test_all_registers_slave2 --gui"
    echo ""
}

# ==============================================================================
# Argument Parsing
# ==============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --test)
                TEST="$2"
                shift 2
                ;;
            --seed)
                SEED="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --coverage)
                COVERAGE=1
                shift
                ;;
            --waves)
                WAVES=1
                shift
                ;;
            --gui)
                GUI=1
                shift
                ;;
            --compile-only)
                COMPILE_ONLY=1
                shift
                ;;
            --skip-compile)
                SKIP_COMPILE=1
                shift
                ;;
            --verbosity)
                VERBOSITY="$2"
                shift 2
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                print_usage
                exit 3
                ;;
        esac
    done
}

# ==============================================================================
# Setup Results Directory
# ==============================================================================
setup_results_dir() {
    RESULTS_DIR="${SIM_DIR}/results"
    mkdir -p "${RESULTS_DIR}"

    # Create timestamped log filename
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="${RESULTS_DIR}/${TEST}_${TIMESTAMP}.log"
    LATEST_LOG="${RESULTS_DIR}/${TEST}.log"
}

# ==============================================================================
# Compile RTL + Testbench
# ==============================================================================
compile_design() {
    info "Compiling RTL and Testbench..."
    echo ""

    # Create work library if needed
    if [[ ! -d "${SIM_DIR}/work" ]]; then
        info "Creating work library..."
        cd "${SIM_DIR}"
        ${VLIB} work
    fi

    cd "${SIM_DIR}"

    # Compiler flags
    local VLOG_FLAGS="-sv +incdir+${RTL_DIR} +incdir+${TB_DIR} -work work -lint"

    if [[ ${COVERAGE} -eq 1 ]]; then
        VLOG_FLAGS="${VLOG_FLAGS} +cover=bcestf"
    fi

    # Compile RTL files
    info "  Compiling RTL files..."
    ${VLOG} ${VLOG_FLAGS} \
        "${RTL_DIR}/apb_master_fsm.v" \
        "${RTL_DIR}/apb_master.v" \
        "${RTL_DIR}/apb_decoder.v" \
        "${RTL_DIR}/apb_mux.v" \
        "${RTL_DIR}/apb_slave.v" \
        "${RTL_DIR}/apb_top.v"

    local rtl_status=$?
    if [[ ${rtl_status} -ne 0 ]]; then
        error "RTL compilation failed! (exit code: ${rtl_status})"
        return 2
    fi

    # Compile TB files
    info "  Compiling Testbench files..."
    ${VLOG} ${VLOG_FLAGS} \
        "${TB_DIR}/apb_if.sv" \
        "${TB_DIR}/apb_assertions.sv" \
        "${TB_DIR}/apb_tb_top.sv"

    local tb_status=$?
    if [[ ${tb_status} -ne 0 ]]; then
        error "Testbench compilation failed! (exit code: ${tb_status})"
        return 2
    fi

    success "Compilation successful."
    echo ""
    return 0
}

# ==============================================================================
# Run Simulation
# ==============================================================================
run_simulation() {
    info "Running simulation..."
    echo ""
    info "  Test:     ${TEST}"
    info "  Seed:     ${SEED}"
    info "  Coverage: $([ ${COVERAGE} -eq 1 ] && echo 'ENABLED' || echo 'disabled')"
    info "  Waves:    $([ ${WAVES} -eq 1 ] && echo 'ENABLED' || echo 'disabled')"
    info "  GUI:      $([ ${GUI} -eq 1 ] && echo 'ENABLED' || echo 'disabled')"
    info "  Timeout:  ${TIMEOUT} ns"
    info "  Log:      ${LOG_FILE}"
    echo ""

    cd "${SIM_DIR}"

    # Build vsim command
    local VSIM_FLAGS=""

    # Seed
    if [[ "${SEED}" == "random" ]]; then
        VSIM_FLAGS="${VSIM_FLAGS} -sv_seed random"
    else
        VSIM_FLAGS="${VSIM_FLAGS} -sv_seed ${SEED}"
    fi

    # Test selection
    VSIM_FLAGS="${VSIM_FLAGS} +${TEST}"

    # Timeout
    VSIM_FLAGS="${VSIM_FLAGS} +TIMEOUT=${TIMEOUT}"

    # Time resolution
    VSIM_FLAGS="${VSIM_FLAGS} -t 1ps"

    # Coverage
    if [[ ${COVERAGE} -eq 1 ]]; then
        VSIM_FLAGS="${VSIM_FLAGS} -coverage"
        VSIM_FLAGS="${VSIM_FLAGS} -coverstore ${RESULTS_DIR}/${TEST}.ucdb"
    fi

    # Waveforms
    if [[ ${WAVES} -eq 1 ]]; then
        VSIM_FLAGS="${VSIM_FLAGS} +WAVE_EN"
        VSIM_FLAGS="${VSIM_FLAGS} -wlf ${RESULTS_DIR}/${TEST}.wlf"
    fi

    # Run simulation
    if [[ ${GUI} -eq 1 ]]; then
        info "Launching QuestaSim GUI..."
        ${VSIM} ${VSIM_FLAGS} \
            -do "do wave.do; run -all" \
            work.apb_tb_top 2>&1 | tee "${LOG_FILE}"
    else
        ${VSIM} -batch ${VSIM_FLAGS} \
            -do "run -all; quit -f" \
            work.apb_tb_top 2>&1 | tee "${LOG_FILE}"
    fi

    local sim_exit=$?

    # Create symlink to latest log for convenience
    ln -sf "$(basename "${LOG_FILE}")" "${LATEST_LOG}" 2>/dev/null || \
        cp "${LOG_FILE}" "${LATEST_LOG}" 2>/dev/null

    return ${sim_exit}
}

# ==============================================================================
# Analyze Results
# ==============================================================================
analyze_results() {
    local log_file="$1"
    local pass=0

    echo ""
    echo "══════════════════════════════════════════════════"
    echo "  Result Analysis"
    echo "══════════════════════════════════════════════════"

    # Check for simulation completion
    if grep -q "Simulation finished" "${log_file}"; then
        info "Simulation completed normally."
    elif grep -q "SIMULATION TIMEOUT" "${log_file}"; then
        error "Simulation TIMED OUT!"
        return 1
    else
        warn "Simulation may not have completed normally."
    fi

    # Check scoreboard result
    if grep -q "ALL CHECKS PASSED" "${log_file}"; then
        success "Scoreboard: ALL CHECKS PASSED"
        pass=1
    elif grep -q "FAILED" "${log_file}"; then
        error "Scoreboard: FAILURES DETECTED"
        echo ""
        echo "  Failure details:"
        grep -n "FAIL\|ERROR" "${log_file}" | head -20 | while read -r line; do
            echo "    ${line}"
        done
        pass=0
    fi

    # Check assertion results
    if grep -q "ALL ASSERTIONS PASSED" "${log_file}"; then
        success "Assertions: ALL PASSED"
    elif grep -q "ASSERTION.*FAILED" "${log_file}"; then
        error "Assertions: FAILURES DETECTED"
        local fail_count
        fail_count=$(grep -c "ASSERTION.*FAIL\|APB_A[0-9].*FAIL" "${log_file}" 2>/dev/null || echo "0")
        echo "    Assertion failures found: ${fail_count}"
        pass=0
    fi

    # Count transfers
    local transfer_count
    transfer_count=$(grep -o "Total Transfers *: *[0-9]*" "${log_file}" | head -1 | grep -o "[0-9]*$" || echo "?")
    info "Total transfers driven: ${transfer_count}"

    # Coverage summary (if enabled)
    if grep -q "OVERALL AVERAGE" "${log_file}"; then
        local cov_pct
        cov_pct=$(grep "OVERALL AVERAGE" "${log_file}" | grep -o "[0-9]*\.[0-9]*" | head -1 || echo "?")
        info "Overall coverage: ${cov_pct}%"
    fi

    echo ""
    echo "══════════════════════════════════════════════════"

    if [[ ${pass} -eq 1 ]]; then
        echo ""
        success "████████████████████████████████████████████████"
        success "  TEST ${TEST}: PASSED"
        success "████████████████████████████████████████████████"
        echo ""
        return 0
    else
        echo ""
        error "████████████████████████████████████████████████"
        error "  TEST ${TEST}: FAILED"
        error "████████████████████████████████████████████████"
        echo ""
        return 1
    fi
}

# ==============================================================================
# Print Summary Banner
# ==============================================================================
print_banner() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     AMBA APB Protocol — Simulation Runner            ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    print_banner
    parse_args "$@"
    setup_results_dir

    # Compile (unless skipped)
    if [[ ${SKIP_COMPILE} -eq 0 ]]; then
        compile_design
        local comp_status=$?
        if [[ ${comp_status} -ne 0 ]]; then
            exit ${comp_status}
        fi
    else
        info "Skipping compilation (--skip-compile)."
    fi

    # Stop here if compile-only
    if [[ ${COMPILE_ONLY} -eq 1 ]]; then
        info "Compile-only mode. Exiting."
        exit 0
    fi

    # Record start time
    local start_time
    start_time=$(date +%s)

    # Run simulation
    run_simulation
    local sim_status=$?

    # Record end time
    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    info "Simulation wall time: ${elapsed}s"

    # Analyze results
    analyze_results "${LOG_FILE}"
    local result=$?

    # Print log location
    echo ""
    info "Full log: ${LOG_FILE}"
    if [[ ${WAVES} -eq 1 ]]; then
        info "Waveform: ${RESULTS_DIR}/${TEST}.wlf"
        info "VCD file: ${SIM_DIR}/apb_sim.vcd"
    fi
    if [[ ${COVERAGE} -eq 1 ]]; then
        info "Coverage: ${RESULTS_DIR}/${TEST}.ucdb"
    fi
    echo ""

    exit ${result}
}

# Run main with all arguments
main "$@"
