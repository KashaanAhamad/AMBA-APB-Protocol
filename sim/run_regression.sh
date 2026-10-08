#!/bin/bash
# ==============================================================================
# Script:  run_regression.sh
# Purpose: Run full APB regression — all tests with result tracking.
#
#          Executes every test from the test list, collects pass/fail results,
#          measures execution time per test, and generates a formatted summary
#          report. Supports parallel execution for faster runtimes.
#
# Usage:
#   ./run_regression.sh                        # Run all tests (sequential)
#   ./run_regression.sh -j 4                   # 4 parallel jobs
#   ./run_regression.sh -l smoke_tests.txt     # Custom test list
#   ./run_regression.sh --rerun-failed         # Rerun only previously failed
#   ./run_regression.sh --coverage             # Enable coverage collection
#   ./run_regression.sh --help
#
# Exit Codes:
#   0 — All tests PASSED
#   1 — One or more tests FAILED
#   2 — Setup / configuration error
# ==============================================================================

set -uo pipefail

# ==============================================================================
# Configuration
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SIM_DIR="${SCRIPT_DIR}"
RTL_DIR="${PROJECT_ROOT}/rtl"
TB_DIR="${PROJECT_ROOT}/tb"

# Tool binaries
VLIB="${VLIB:-vlib}"
VLOG="${VLOG:-vlog}"
VSIM="${VSIM:-vsim}"

# Default parameters
MAX_PARALLEL=1
COVERAGE=0
SEED="random"
TIMEOUT="10000000"
RERUN_FAILED=0
CUSTOM_TEST_LIST=""
COMPILE_FIRST=1

# Results tracking
RESULTS_DIR="${SIM_DIR}/results"
REPORT_FILE="${RESULTS_DIR}/regression_report.txt"
FAILED_LIST="${RESULTS_DIR}/failed_tests.txt"

# ==============================================================================
# Default Test List
# ==============================================================================
DEFAULT_TESTS=(
    "test_single_write"
    "test_single_read"
    "test_write_read_all_slaves"
    "test_all_registers_slave0"
    "test_all_registers_slave1"
    "test_all_registers_slave2"
    "test_wait_state_timing"
    "test_back_to_back_same_slave"
    "test_back_to_back_diff_slave"
    "test_b2b_write_read"
    "test_b2b_read_read"
    "test_b2b_read_write"
    "test_unaligned_addr"
    "test_invalid_addr_range"
    "test_reset_during_idle"
    "test_reset_during_transfer"
    "test_reset_clears_registers"
    "test_data_walking_ones"
    "test_data_walking_zeros"
    "test_data_all_ones_zeros"
    "test_data_checkerboard"
    "test_random_stress_100"
    "test_random_stress_1000"
    "test_slave2_burst_wait"
)

# ==============================================================================
# Color Output Helpers
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

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
    echo "  -j <N>             Max parallel jobs (default: 1 = sequential)"
    echo "  -l <file>          Custom test list file (one test per line)"
    echo "  --seed <int|random> Random seed for all tests (default: random)"
    echo "  --timeout <ns>     Per-test timeout in ns (default: 10000000)"
    echo "  --coverage         Enable coverage collection per test"
    echo "  --rerun-failed     Rerun only tests from failed_tests.txt"
    echo "  --skip-compile     Skip compilation (use existing work library)"
    echo "  --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0")                    # Run all 24 tests sequentially"
    echo "  $(basename "$0") -j 4 --coverage    # 4 parallel, with coverage"
    echo "  $(basename "$0") --rerun-failed     # Rerun only failures"
    echo "  $(basename "$0") -l my_tests.txt    # Custom test list"
    echo ""
    echo "Test list format (one test per line, # comments allowed):"
    echo "  test_single_write"
    echo "  test_single_read"
    echo "  # test_random_stress_10000  (commented out = skipped)"
    echo ""
}

# ==============================================================================
# Argument Parsing
# ==============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -j)
                MAX_PARALLEL="$2"
                shift 2
                ;;
            -l)
                CUSTOM_TEST_LIST="$2"
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
            --rerun-failed)
                RERUN_FAILED=1
                shift
                ;;
            --skip-compile)
                COMPILE_FIRST=0
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                print_usage
                exit 2
                ;;
        esac
    done
}

# ==============================================================================
# Load Test List
# ==============================================================================
load_test_list() {
    TESTS=()

    if [[ ${RERUN_FAILED} -eq 1 ]]; then
        # Load from failed_tests.txt
        if [[ -f "${FAILED_LIST}" ]]; then
            while IFS= read -r line; do
                # Skip empty lines and comments
                line=$(echo "${line}" | sed 's/#.*//' | xargs)
                [[ -z "${line}" ]] && continue
                TESTS+=("${line}")
            done < "${FAILED_LIST}"
            info "Loaded ${#TESTS[@]} failed test(s) from ${FAILED_LIST}"
        else
            error "No failed_tests.txt found. Run a full regression first."
            exit 2
        fi
    elif [[ -n "${CUSTOM_TEST_LIST}" ]]; then
        # Load from custom file
        if [[ -f "${CUSTOM_TEST_LIST}" ]]; then
            while IFS= read -r line; do
                line=$(echo "${line}" | sed 's/#.*//' | xargs)
                [[ -z "${line}" ]] && continue
                TESTS+=("${line}")
            done < "${CUSTOM_TEST_LIST}"
            info "Loaded ${#TESTS[@]} test(s) from ${CUSTOM_TEST_LIST}"
        else
            error "Test list file not found: ${CUSTOM_TEST_LIST}"
            exit 2
        fi
    else
        # Use default test list
        TESTS=("${DEFAULT_TESTS[@]}")
        info "Using default test list: ${#TESTS[@]} tests"
    fi

    if [[ ${#TESTS[@]} -eq 0 ]]; then
        error "No tests to run!"
        exit 2
    fi
}

# ==============================================================================
# Compile Design (Once Before Regression)
# ==============================================================================
compile_design() {
    info "Compiling RTL and Testbench..."
    cd "${SIM_DIR}"

    # Create work library if needed
    if [[ ! -d "${SIM_DIR}/work" ]]; then
        ${VLIB} work
    fi

    local VLOG_FLAGS="-sv +incdir+${RTL_DIR} +incdir+${TB_DIR} -work work -lint"
    if [[ ${COVERAGE} -eq 1 ]]; then
        VLOG_FLAGS="${VLOG_FLAGS} +cover=bcestf"
    fi

    # Compile RTL
    ${VLOG} ${VLOG_FLAGS} \
        "${RTL_DIR}/apb_master_fsm.v" \
        "${RTL_DIR}/apb_master.v" \
        "${RTL_DIR}/apb_decoder.v" \
        "${RTL_DIR}/apb_mux.v" \
        "${RTL_DIR}/apb_slave.v" \
        "${RTL_DIR}/apb_top.v" || { error "RTL compilation failed!"; exit 2; }

    # Compile TB
    ${VLOG} ${VLOG_FLAGS} \
        "${TB_DIR}/apb_if.sv" \
        "${TB_DIR}/apb_assertions.sv" \
        "${TB_DIR}/apb_tb_top.sv" || { error "TB compilation failed!"; exit 2; }

    success "Compilation successful."
    echo ""
}

# ==============================================================================
# Run Single Test (called per test)
# ==============================================================================
run_single_test() {
    local test_name="$1"
    local log_file="${RESULTS_DIR}/${test_name}.log"

    cd "${SIM_DIR}"

    # Build vsim command
    local VSIM_FLAGS="-batch -t 1ps"

    if [[ "${SEED}" == "random" ]]; then
        VSIM_FLAGS="${VSIM_FLAGS} -sv_seed random"
    else
        VSIM_FLAGS="${VSIM_FLAGS} -sv_seed ${SEED}"
    fi

    VSIM_FLAGS="${VSIM_FLAGS} +${test_name}"
    VSIM_FLAGS="${VSIM_FLAGS} +TIMEOUT=${TIMEOUT}"

    if [[ ${COVERAGE} -eq 1 ]]; then
        VSIM_FLAGS="${VSIM_FLAGS} -coverage"
        VSIM_FLAGS="${VSIM_FLAGS} -coverstore ${RESULTS_DIR}/${test_name}.ucdb"
    fi

    # Run simulation
    ${VSIM} ${VSIM_FLAGS} \
        -do "run -all; quit -f" \
        work.apb_tb_top > "${log_file}" 2>&1

    local exit_code=$?

    # Determine pass/fail from log content
    local status="FAIL"
    if [[ ${exit_code} -eq 0 ]] && grep -q "ALL CHECKS PASSED" "${log_file}" 2>/dev/null; then
        if grep -q "ALL ASSERTIONS PASSED" "${log_file}" 2>/dev/null || \
           ! grep -q "ASSERTION.*FAILED" "${log_file}" 2>/dev/null; then
            status="PASS"
        fi
    fi

    echo "${status}"
}

# ==============================================================================
# Run All Tests (Sequential)
# ==============================================================================
run_sequential() {
    local total=${#TESTS[@]}
    local current=0
    local pass_count=0
    local fail_count=0
    local -a results_status=()
    local -a results_time=()

    for test_name in "${TESTS[@]}"; do
        current=$((current + 1))

        echo -e "${DIM}────────────────────────────────────────────────${NC}"
        echo -e "  [${current}/${total}] Running: ${BOLD}${test_name}${NC}"

        local start_time
        start_time=$(date +%s)

        local status
        status=$(run_single_test "${test_name}")

        local end_time
        end_time=$(date +%s)
        local elapsed=$((end_time - start_time))

        results_status+=("${status}")
        results_time+=("${elapsed}")

        if [[ "${status}" == "PASS" ]]; then
            success "  ${test_name}: PASSED  (${elapsed}s)"
            pass_count=$((pass_count + 1))
        else
            error "  ${test_name}: FAILED  (${elapsed}s)"
            fail_count=$((fail_count + 1))
        fi
    done

    # Store results for report generation
    TOTAL_TESTS=${total}
    TOTAL_PASS=${pass_count}
    TOTAL_FAIL=${fail_count}
    RESULT_STATUSES=("${results_status[@]}")
    RESULT_TIMES=("${results_time[@]}")
}

# ==============================================================================
# Run All Tests (Parallel)
# ==============================================================================
run_parallel() {
    local total=${#TESTS[@]}
    local pass_count=0
    local fail_count=0
    local -a results_status=()
    local -a results_time=()
    local -a pids=()
    local -a pid_tests=()
    local -a start_times=()

    info "Running ${total} tests with max ${MAX_PARALLEL} parallel jobs..."
    echo ""

    local running=0
    local launched=0

    for test_name in "${TESTS[@]}"; do
        # Wait if we've hit the parallel limit
        while [[ ${running} -ge ${MAX_PARALLEL} ]]; do
            # Wait for any child to finish
            wait -n 2>/dev/null || true
            # Recount running processes
            running=0
            for pid in "${pids[@]}"; do
                if kill -0 "${pid}" 2>/dev/null; then
                    running=$((running + 1))
                fi
            done
        done

        # Launch test in background
        local start_time
        start_time=$(date +%s)
        start_times+=("${start_time}")

        echo -e "  Launching: ${test_name}"
        run_single_test "${test_name}" > "${RESULTS_DIR}/${test_name}.status" &
        pids+=($!)
        pid_tests+=("${test_name}")
        running=$((running + 1))
        launched=$((launched + 1))
    done

    # Wait for all remaining jobs
    info "Waiting for all ${launched} tests to complete..."
    wait

    # Collect results
    for i in "${!pid_tests[@]}"; do
        local test_name="${pid_tests[$i]}"
        local status_file="${RESULTS_DIR}/${test_name}.status"
        local end_time
        end_time=$(date +%s)
        local elapsed=$((end_time - ${start_times[$i]}))

        local status="FAIL"
        if [[ -f "${status_file}" ]]; then
            status=$(cat "${status_file}")
            rm -f "${status_file}"
        fi

        results_status+=("${status}")
        results_time+=("${elapsed}")

        if [[ "${status}" == "PASS" ]]; then
            pass_count=$((pass_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    TOTAL_TESTS=${total}
    TOTAL_PASS=${pass_count}
    TOTAL_FAIL=${fail_count}
    RESULT_STATUSES=("${results_status[@]}")
    RESULT_TIMES=("${results_time[@]}")
}

# ==============================================================================
# Generate Report
# ==============================================================================
generate_report() {
    local total_time=0
    for t in "${RESULT_TIMES[@]}"; do
        total_time=$((total_time + t))
    done

    # Build report to both stdout and file
    {
        echo ""
        echo "╔══════════════════════════════════════════════════════════════════════╗"
        echo "║                   AMBA APB Regression Report                         ║"
        echo "║  Date: $(date '+%Y-%m-%d %H:%M:%S')                                            ║"
        echo "╠══════════════════════════════════════════════════════════════════════╣"
        echo "║                                                                      ║"
        printf "║  %-40s │ %-6s │ %6s   ║\n" "Test Name" "Status" "Time"
        echo "║  ────────────────────────────────────────┼────────┼──────────║"

        for i in "${!TESTS[@]}"; do
            local test_name="${TESTS[$i]}"
            local status="${RESULT_STATUSES[$i]}"
            local elapsed="${RESULT_TIMES[$i]}"

            if [[ "${status}" == "PASS" ]]; then
                printf "║  %-40s │  PASS  │  %4ds   ║\n" "${test_name}" "${elapsed}"
            else
                printf "║  %-40s │  FAIL  │  %4ds   ║\n" "${test_name}" "${elapsed}"
            fi
        done

        echo "║                                                                      ║"
        echo "╠══════════════════════════════════════════════════════════════════════╣"
        printf "║  Total: %-4d │ Passed: %-4d │ Failed: %-4d │ Time: %ds        ║\n" \
            "${TOTAL_TESTS}" "${TOTAL_PASS}" "${TOTAL_FAIL}" "${total_time}"
        echo "╠══════════════════════════════════════════════════════════════════════╣"

        if [[ ${TOTAL_FAIL} -eq 0 ]]; then
            echo "║                                                                      ║"
            echo "║              ALL TESTS PASSED                                        ║"
            echo "║                                                                      ║"
        else
            echo "║                                                                      ║"
            echo "║              ${TOTAL_FAIL} TEST(S) FAILED                                       ║"
            echo "║                                                                      ║"
        fi

        echo "╚══════════════════════════════════════════════════════════════════════╝"
        echo ""
    } | tee "${REPORT_FILE}"

    # Write failed tests list (for --rerun-failed)
    > "${FAILED_LIST}"
    for i in "${!TESTS[@]}"; do
        if [[ "${RESULT_STATUSES[$i]}" == "FAIL" ]]; then
            echo "${TESTS[$i]}" >> "${FAILED_LIST}"
        fi
    done

    if [[ ${TOTAL_FAIL} -gt 0 ]]; then
        warn "Failed test list saved to: ${FAILED_LIST}"
        warn "Rerun with: $(basename "$0") --rerun-failed"
        echo ""
    fi

    info "Full report saved to: ${REPORT_FILE}"
    info "Individual logs in: ${RESULTS_DIR}/"
    echo ""
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     AMBA APB Protocol — Regression Runner                ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    parse_args "$@"
    load_test_list

    # Setup results directory
    mkdir -p "${RESULTS_DIR}"

    # Compile once before running tests
    if [[ ${COMPILE_FIRST} -eq 1 ]]; then
        compile_design
    fi

    # Record total start time
    local regression_start
    regression_start=$(date +%s)

    info "Starting regression: ${#TESTS[@]} tests, max parallel: ${MAX_PARALLEL}"
    echo ""

    # Run tests
    if [[ ${MAX_PARALLEL} -gt 1 ]]; then
        run_parallel
    else
        run_sequential
    fi

    # Record total end time
    local regression_end
    regression_end=$(date +%s)
    local total_wall=$((regression_end - regression_start))

    info "Regression wall time: ${total_wall}s"

    # Generate report
    generate_report

    # Exit with appropriate code
    if [[ ${TOTAL_FAIL} -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
