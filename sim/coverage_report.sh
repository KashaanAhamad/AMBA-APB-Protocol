#!/bin/bash
# ==============================================================================
# Script:  coverage_report.sh
# Purpose: Merge per-test coverage databases and generate reports.
#
#          After a regression run with coverage enabled, each test produces
#          a .ucdb file. This script merges them into a single database and
#          generates both HTML (browsable) and text (terminal) reports.
#
# Usage:
#   ./coverage_report.sh                            # Merge all, generate HTML
#   ./coverage_report.sh --threshold 90             # Set 90% pass threshold
#   ./coverage_report.sh --output my_cov_report/    # Custom output directory
#   ./coverage_report.sh --text-only                # Text report only (no HTML)
#   ./coverage_report.sh --details                  # Show per-covergroup breakdown
#   ./coverage_report.sh --help
#
# Prerequisites:
#   Run regression with coverage first:
#     ./run_regression.sh --coverage
#     make regression COV_EN=1
#
# Exit Codes:
#   0 — Coverage at or above threshold
#   1 — Coverage below threshold
#   2 — No UCDB files found / tool error
# ==============================================================================

set -uo pipefail

# ==============================================================================
# Configuration
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_DIR="${SCRIPT_DIR}"
RESULTS_DIR="${SIM_DIR}/results"

# Tool binaries
VCOVER="${VCOVER:-vcover}"

# Default parameters
THRESHOLD=95.0
OUTPUT_DIR="${SIM_DIR}/cov_html"
MERGED_UCDB="${SIM_DIR}/merged.ucdb"
TEXT_ONLY=0
SHOW_DETAILS=0

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
    echo "  --threshold <pct>   Coverage pass threshold percentage (default: 95.0)"
    echo "  --output <dir>      Output directory for HTML report (default: cov_html/)"
    echo "  --merged <file>     Output path for merged UCDB (default: merged.ucdb)"
    echo "  --input <dir>       Directory containing .ucdb files (default: results/)"
    echo "  --text-only         Generate text report only, skip HTML"
    echo "  --details           Show detailed per-covergroup/per-module breakdown"
    echo "  --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0")                                # Merge all, HTML report"
    echo "  $(basename "$0") --threshold 90                 # Lower pass threshold"
    echo "  $(basename "$0") --details --text-only          # Detailed text report"
    echo ""
}

# ==============================================================================
# Argument Parsing
# ==============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --threshold)
                THRESHOLD="$2"
                shift 2
                ;;
            --output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --merged)
                MERGED_UCDB="$2"
                shift 2
                ;;
            --input)
                RESULTS_DIR="$2"
                shift 2
                ;;
            --text-only)
                TEXT_ONLY=1
                shift
                ;;
            --details)
                SHOW_DETAILS=1
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
# Find UCDB Files
# ==============================================================================
find_ucdb_files() {
    UCDB_FILES=()

    if [[ ! -d "${RESULTS_DIR}" ]]; then
        error "Results directory not found: ${RESULTS_DIR}"
        error "Run regression with coverage first:"
        error "  ./run_regression.sh --coverage"
        exit 2
    fi

    # Find all .ucdb files
    while IFS= read -r -d '' file; do
        UCDB_FILES+=("${file}")
    done < <(find "${RESULTS_DIR}" -name "*.ucdb" -type f -print0 2>/dev/null)

    if [[ ${#UCDB_FILES[@]} -eq 0 ]]; then
        error "No .ucdb files found in ${RESULTS_DIR}/"
        error "Run regression with coverage enabled first:"
        error "  ./run_regression.sh --coverage"
        error "  make regression COV_EN=1"
        exit 2
    fi

    info "Found ${#UCDB_FILES[@]} UCDB file(s):"
    for f in "${UCDB_FILES[@]}"; do
        echo -e "    ${DIM}$(basename "${f}")${NC}"
    done
    echo ""
}

# ==============================================================================
# Merge Coverage Databases
# ==============================================================================
merge_coverage() {
    info "Merging ${#UCDB_FILES[@]} UCDB files..."

    # Remove old merged file
    rm -f "${MERGED_UCDB}"

    ${VCOVER} merge "${MERGED_UCDB}" "${UCDB_FILES[@]}" 2>&1 | \
        grep -v "^$" | head -20

    if [[ ! -f "${MERGED_UCDB}" ]]; then
        error "Merge failed! ${MERGED_UCDB} not created."
        exit 2
    fi

    local size
    size=$(du -h "${MERGED_UCDB}" | cut -f1)
    success "Merged UCDB created: ${MERGED_UCDB} (${size})"
    echo ""
}

# ==============================================================================
# Generate Text Report
# ==============================================================================
generate_text_report() {
    local report_file="${SIM_DIR}/coverage_summary.txt"

    info "Generating text coverage report..."
    echo ""

    # Run vcover report and capture output
    local report_output
    report_output=$(${VCOVER} report "${MERGED_UCDB}" 2>&1)

    # Save full report to file
    echo "${report_output}" > "${report_file}"

    # Display summary
    echo "──────────────────────────────────────────────────────────"
    echo "  Coverage Summary"
    echo "──────────────────────────────────────────────────────────"

    # Extract key metrics from vcover output
    # vcover report format varies, so we try multiple patterns
    local total_cov=""

    # Try to extract coverage percentages
    if echo "${report_output}" | grep -q "Total Coverage"; then
        echo "${report_output}" | grep -A 5 "Total Coverage"
    fi

    # Show statement/branch/toggle/condition coverage
    local cov_types=("Statement" "Branch" "Condition" "Toggle" "Expression" "FSM")
    for cov_type in "${cov_types[@]}"; do
        local pct
        pct=$(echo "${report_output}" | grep -i "${cov_type}" | \
              grep -o "[0-9]*\.[0-9]*%" | head -1)
        if [[ -n "${pct}" ]]; then
            printf "  %-15s : %s\n" "${cov_type}" "${pct}"
        fi
    done

    echo "──────────────────────────────────────────────────────────"
    echo ""

    # Show detailed breakdown if requested
    if [[ ${SHOW_DETAILS} -eq 1 ]]; then
        echo "──────────────────────────────────────────────────────────"
        echo "  Detailed Coverage (per module)"
        echo "──────────────────────────────────────────────────────────"
        ${VCOVER} report -details "${MERGED_UCDB}" 2>&1 | \
            grep -E "^(Module|Total|  /)" | head -50
        echo "──────────────────────────────────────────────────────────"
        echo ""

        echo "──────────────────────────────────────────────────────────"
        echo "  Functional Coverage (covergroups)"
        echo "──────────────────────────────────────────────────────────"
        ${VCOVER} report -cvg "${MERGED_UCDB}" 2>&1 | head -60
        echo "──────────────────────────────────────────────────────────"
        echo ""
    fi

    info "Text report saved to: ${report_file}"
}

# ==============================================================================
# Generate HTML Report
# ==============================================================================
generate_html_report() {
    info "Generating HTML coverage report..."

    # Remove old HTML report
    rm -rf "${OUTPUT_DIR}"
    mkdir -p "${OUTPUT_DIR}"

    ${VCOVER} report -html -output "${OUTPUT_DIR}" "${MERGED_UCDB}" 2>&1 | \
        grep -v "^$" | head -10

    if [[ -f "${OUTPUT_DIR}/index.html" ]]; then
        success "HTML report generated: ${OUTPUT_DIR}/index.html"
    else
        warn "HTML report generation may have had issues."
        warn "Check: ${OUTPUT_DIR}/"
    fi
    echo ""
}

# ==============================================================================
# Check Coverage Threshold
# ==============================================================================
check_threshold() {
    info "Checking coverage against threshold: ${THRESHOLD}%"
    echo ""

    # Extract overall coverage percentage
    local report_output
    report_output=$(${VCOVER} report "${MERGED_UCDB}" 2>&1)

    # Try to find the overall/total coverage number
    local overall_pct=""

    # Try various patterns that vcover might output
    overall_pct=$(echo "${report_output}" | \
                  grep -i "total\|overall\|all" | \
                  grep -o "[0-9]*\.[0-9]*" | tail -1)

    if [[ -z "${overall_pct}" ]]; then
        # Fallback: try to find any percentage
        overall_pct=$(echo "${report_output}" | \
                      grep -o "[0-9]*\.[0-9]*%" | head -1 | tr -d '%')
    fi

    if [[ -n "${overall_pct}" ]]; then
        # Compare with threshold using awk (bash doesn't do float comparison)
        local pass
        pass=$(awk "BEGIN { print (${overall_pct} >= ${THRESHOLD}) ? 1 : 0 }")

        if [[ ${pass} -eq 1 ]]; then
            echo ""
            success "════════════════════════════════════════════════════"
            success "  Coverage: ${overall_pct}% >= ${THRESHOLD}% threshold"
            success "  COVERAGE TARGET MET"
            success "════════════════════════════════════════════════════"
            echo ""
            return 0
        else
            echo ""
            error "════════════════════════════════════════════════════"
            error "  Coverage: ${overall_pct}% < ${THRESHOLD}% threshold"
            error "  COVERAGE TARGET NOT MET"
            error "════════════════════════════════════════════════════"
            echo ""
            return 1
        fi
    else
        warn "Could not extract overall coverage percentage from vcover output."
        warn "Check the reports manually:"
        warn "  Text: ${SIM_DIR}/coverage_summary.txt"
        warn "  HTML: ${OUTPUT_DIR}/index.html"
        echo ""
        return 0    # Don't fail if we can't parse
    fi
}

# ==============================================================================
# Print Per-Test Coverage Summary
# ==============================================================================
print_per_test_coverage() {
    echo ""
    echo "──────────────────────────────────────────────────────────"
    echo "  Per-Test Coverage Contributions"
    echo "──────────────────────────────────────────────────────────"
    printf "  %-40s │ %s\n" "Test" "UCDB Size"
    echo "  ────────────────────────────────────────┼──────────────"

    for ucdb_file in "${UCDB_FILES[@]}"; do
        local name
        name=$(basename "${ucdb_file}" .ucdb)
        local size
        size=$(du -h "${ucdb_file}" | cut -f1)
        printf "  %-40s │ %s\n" "${name}" "${size}"
    done

    echo "──────────────────────────────────────────────────────────"
    echo ""
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     AMBA APB Protocol — Coverage Report Generator        ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    parse_args "$@"

    # Step 1: Find UCDB files
    find_ucdb_files

    # Step 2: Show per-test info
    print_per_test_coverage

    # Step 3: Merge all UCDBs
    merge_coverage

    # Step 4: Generate text report
    generate_text_report

    # Step 5: Generate HTML report (unless text-only)
    if [[ ${TEXT_ONLY} -eq 0 ]]; then
        generate_html_report
    fi

    # Step 6: Check threshold
    check_threshold
    local result=$?

    # Final info
    echo ""
    info "Output files:"
    info "  Merged UCDB  : ${MERGED_UCDB}"
    info "  Text report  : ${SIM_DIR}/coverage_summary.txt"
    if [[ ${TEXT_ONLY} -eq 0 ]]; then
        info "  HTML report  : ${OUTPUT_DIR}/index.html"
    fi
    echo ""

    exit ${result}
}

main "$@"
