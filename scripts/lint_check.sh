#!/bin/bash
# ==============================================================================
# Script:  lint_check.sh
# Purpose: Run static lint checks on RTL source files using Verilator.
#
#          Catches common coding issues without running a full simulation:
#            - Undriven / unused signals
#            - Width mismatches in assignments and operations
#            - Latch inference from incomplete sensitivity lists
#            - Missing case defaults
#            - Implicit net declarations
#            - Combinational loops
#
# Usage:
#   ./scripts/lint_check.sh                    # Lint all RTL files
#   ./scripts/lint_check.sh --file apb_top.v   # Lint specific file
#   ./scripts/lint_check.sh --strict           # Enable all warnings as errors
#   ./scripts/lint_check.sh --suppress W_UNUSED # Suppress specific warnings
#   ./scripts/lint_check.sh --help
#
# Prerequisites:
#   Verilator must be installed. Install via:
#     Ubuntu/Debian:  sudo apt install verilator
#     Fedora/RHEL:    sudo dnf install verilator
#     macOS:          brew install verilator
#
# Exit Codes:
#   0 — No lint errors
#   1 — Lint errors found
#   2 — Tool not found or configuration error
# ==============================================================================

set -uo pipefail

# ==============================================================================
# Configuration
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RTL_DIR="${PROJECT_ROOT}/rtl"
SIM_DIR="${PROJECT_ROOT}/sim"

# Tool binary
VERILATOR="${VERILATOR:-verilator}"

# Default parameters
LINT_TARGET="all"           # "all" or specific filename
STRICT_MODE=0               # 1 = treat all warnings as errors
SUPPRESS_LIST=()            # Warnings to suppress
OUTPUT_LOG="${SIM_DIR}/lint_report.txt"

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

info()    { echo -e "${CYAN}[LINT]${NC} $*"; }
success() { echo -e "${GREEN}[LINT]${NC} $*"; }
error()   { echo -e "${RED}[LINT]${NC} $*"; }
warn()    { echo -e "${YELLOW}[LINT]${NC} $*"; }

# ==============================================================================
# Usage / Help
# ==============================================================================
print_usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} $(basename "$0") [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --file <name>          Lint a specific file (e.g., apb_top.v)"
    echo "  --strict               Treat all warnings as errors (-Werror-*)"
    echo "  --suppress <WARNID>    Suppress a specific warning (repeatable)"
    echo "  --output <path>        Output log path (default: sim/lint_report.txt)"
    echo "  --help                 Show this help message"
    echo ""
    echo "Suppression IDs (common):"
    echo "  UNUSED         Unused signal warnings"
    echo "  UNDRIVEN       Undriven signal warnings"
    echo "  WIDTH          Width mismatch warnings"
    echo "  PINMISSING     Missing port connection"
    echo "  CASEINCOMPLETE Missing default in case"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0")                               # Lint all RTL"
    echo "  $(basename "$0") --file apb_slave.v            # Lint one file"
    echo "  $(basename "$0") --strict                      # Strict mode"
    echo "  $(basename "$0") --suppress UNUSED             # Suppress unused warnings"
    echo ""
}

# ==============================================================================
# Argument Parsing
# ==============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)
                LINT_TARGET="$2"
                shift 2
                ;;
            --strict)
                STRICT_MODE=1
                shift
                ;;
            --suppress)
                SUPPRESS_LIST+=("$2")
                shift 2
                ;;
            --output)
                OUTPUT_LOG="$2"
                shift 2
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
# Check Verilator Availability
# ==============================================================================
check_verilator() {
    if ! command -v "${VERILATOR}" &>/dev/null; then
        error "Verilator not found on PATH!"
        echo ""
        echo "  Install Verilator:"
        echo "    Ubuntu/Debian:  sudo apt install verilator"
        echo "    Fedora/RHEL:    sudo dnf install verilator"
        echo "    macOS:          brew install verilator"
        echo "    From source:    https://verilator.org/guide/latest/install.html"
        echo ""
        exit 2
    fi

    local version
    version=$(${VERILATOR} --version 2>&1 | head -1)
    info "Using: ${version}"
}

# ==============================================================================
# Build File List
# ==============================================================================
build_file_list() {
    FILES=()

    if [[ "${LINT_TARGET}" == "all" ]]; then
        # All RTL files in compile order
        FILES=(
            "${RTL_DIR}/apb_master_fsm.v"
            "${RTL_DIR}/apb_master.v"
            "${RTL_DIR}/apb_decoder.v"
            "${RTL_DIR}/apb_mux.v"
            "${RTL_DIR}/apb_slave.v"
            "${RTL_DIR}/apb_top.v"
        )
    else
        # Specific file
        if [[ -f "${RTL_DIR}/${LINT_TARGET}" ]]; then
            FILES=("${RTL_DIR}/${LINT_TARGET}")
        elif [[ -f "${LINT_TARGET}" ]]; then
            FILES=("${LINT_TARGET}")
        else
            error "File not found: ${LINT_TARGET}"
            error "Searched: ${RTL_DIR}/${LINT_TARGET} and ${LINT_TARGET}"
            exit 2
        fi
    fi

    info "Files to lint: ${#FILES[@]}"
    for f in "${FILES[@]}"; do
        echo -e "    ${DIM}$(basename "${f}")${NC}"
    done
    echo ""
}

# ==============================================================================
# Build Verilator Flags
# ==============================================================================
build_flags() {
    VERILATOR_FLAGS=(
        "--lint-only"               # Lint only, don't compile
        "-Wall"                     # Enable all warnings
        "+incdir+${RTL_DIR}"        # Include path for RTL
    )

    # Strict mode: treat all warnings as errors
    if [[ ${STRICT_MODE} -eq 1 ]]; then
        VERILATOR_FLAGS+=("-Werror-WIDTH")
        VERILATOR_FLAGS+=("-Werror-UNUSED")
        VERILATOR_FLAGS+=("-Werror-UNDRIVEN")
        VERILATOR_FLAGS+=("-Werror-PINMISSING")
        VERILATOR_FLAGS+=("-Werror-IMPLICIT")
        VERILATOR_FLAGS+=("-Werror-CASEINCOMPLETE")
        info "Strict mode: warnings promoted to errors."
    fi

    # Suppress specific warnings
    for suppress_id in "${SUPPRESS_LIST[@]}"; do
        VERILATOR_FLAGS+=("-Wno-${suppress_id}")
        info "Suppressing: -Wno-${suppress_id}"
    done
}

# ==============================================================================
# Run Lint Check — Per File
# ==============================================================================
lint_single_file() {
    local file="$1"
    local basename_f
    basename_f=$(basename "${file}")

    local output
    local exit_code

    output=$(${VERILATOR} "${VERILATOR_FLAGS[@]}" "${file}" 2>&1)
    exit_code=$?

    local warnings=0
    local errors=0

    warnings=$(echo "${output}" | grep -c "%Warning" 2>/dev/null || echo "0")
    errors=$(echo "${output}" | grep -c "%Error" 2>/dev/null || echo "0")

    if [[ ${exit_code} -eq 0 && ${errors} -eq 0 && ${warnings} -eq 0 ]]; then
        printf "  %-25s  ${GREEN}CLEAN${NC}\n" "${basename_f}"
    elif [[ ${errors} -gt 0 ]]; then
        printf "  %-25s  ${RED}%d error(s), %d warning(s)${NC}\n" "${basename_f}" "${errors}" "${warnings}"
    else
        printf "  %-25s  ${YELLOW}%d warning(s)${NC}\n" "${basename_f}" "${warnings}"
    fi

    # Append to log
    {
        echo "================================================================"
        echo "  File: ${basename_f}"
        echo "  Status: exit_code=${exit_code} errors=${errors} warnings=${warnings}"
        echo "================================================================"
        echo "${output}"
        echo ""
    } >> "${OUTPUT_LOG}"

    return ${exit_code}
}

# ==============================================================================
# Run Lint Check — All Files Together (Top-Level)
# ==============================================================================
lint_all_together() {
    info "Running full-design lint (all files together)..."
    echo ""

    local output
    local exit_code

    output=$(${VERILATOR} "${VERILATOR_FLAGS[@]}" \
             --top-module apb_top \
             "${FILES[@]}" 2>&1)
    exit_code=$?

    local warnings=0
    local errors=0

    warnings=$(echo "${output}" | grep -c "%Warning" 2>/dev/null || echo "0")
    errors=$(echo "${output}" | grep -c "%Error" 2>/dev/null || echo "0")

    # Append to log
    {
        echo "================================================================"
        echo "  FULL DESIGN LINT (top-module: apb_top)"
        echo "  Status: exit_code=${exit_code} errors=${errors} warnings=${warnings}"
        echo "================================================================"
        echo "${output}"
        echo ""
    } >> "${OUTPUT_LOG}"

    # Display the output with some formatting
    if [[ -n "${output}" ]]; then
        echo "──────────────────────────────────────────────────────────"
        echo "  Verilator Output (full design):"
        echo "──────────────────────────────────────────────────────────"
        echo "${output}" | while IFS= read -r line; do
            if echo "${line}" | grep -q "%Error"; then
                echo -e "    ${RED}${line}${NC}"
            elif echo "${line}" | grep -q "%Warning"; then
                echo -e "    ${YELLOW}${line}${NC}"
            else
                echo "    ${line}"
            fi
        done
        echo "──────────────────────────────────────────────────────────"
    fi

    TOTAL_ERRORS=${errors}
    TOTAL_WARNINGS=${warnings}

    return ${exit_code}
}

# ==============================================================================
# Summary Report
# ==============================================================================
print_summary() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              Lint Check Summary                          ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    printf "║  Files checked  : %-6d                                  ║\n" "${#FILES[@]}"
    printf "║  Errors         : %-6d                                  ║\n" "${TOTAL_ERRORS}"
    printf "║  Warnings       : %-6d                                  ║\n" "${TOTAL_WARNINGS}"
    echo "╠══════════════════════════════════════════════════════════╣"

    if [[ ${TOTAL_ERRORS} -eq 0 && ${TOTAL_WARNINGS} -eq 0 ]]; then
        echo "║    LINT CHECK PASSED — No issues found                  ║"
    elif [[ ${TOTAL_ERRORS} -eq 0 ]]; then
        echo "║    LINT CHECK PASSED — Warnings only                    ║"
    else
        echo "║    LINT CHECK FAILED — Errors found                     ║"
    fi

    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    info "Full report: ${OUTPUT_LOG}"
    echo ""
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     AMBA APB Protocol — RTL Lint Checker                 ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    parse_args "$@"
    check_verilator
    build_file_list
    build_flags

    # Ensure output directory exists
    mkdir -p "$(dirname "${OUTPUT_LOG}")"

    # Clear old log
    > "${OUTPUT_LOG}"
    {
        echo "AMBA APB — Lint Check Report"
        echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Tool: $(${VERILATOR} --version 2>&1 | head -1)"
        echo "Mode: $([ ${STRICT_MODE} -eq 1 ] && echo 'STRICT' || echo 'NORMAL')"
        echo ""
    } >> "${OUTPUT_LOG}"

    # Run per-file lint
    echo "──────────────────────────────────────────────────────────"
    echo "  Per-File Lint Results"
    echo "──────────────────────────────────────────────────────────"

    local any_file_error=0
    for file in "${FILES[@]}"; do
        lint_single_file "${file}" || any_file_error=1
    done

    echo "──────────────────────────────────────────────────────────"
    echo ""

    # Run full-design lint (catches cross-module issues)
    if [[ "${LINT_TARGET}" == "all" ]]; then
        lint_all_together
        local full_exit=$?
    else
        TOTAL_ERRORS=0
        TOTAL_WARNINGS=0
        # Count from the per-file run
        TOTAL_ERRORS=$(grep -c "%Error" "${OUTPUT_LOG}" 2>/dev/null || echo "0")
        TOTAL_WARNINGS=$(grep -c "%Warning" "${OUTPUT_LOG}" 2>/dev/null || echo "0")
    fi

    # Print summary
    print_summary

    # Exit code
    if [[ ${TOTAL_ERRORS} -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
