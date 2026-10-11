#!/bin/bash
# ==============================================================================
# Script:  clean.sh
# Purpose: Remove all generated files from the AMBA APB project.
#
#          Supports selective cleaning — remove only simulation artifacts,
#          only synthesis outputs, or everything. Includes a dry-run mode
#          to preview what will be deleted before actually deleting.
#
# Usage:
#   ./scripts/clean.sh              # Clean everything
#   ./scripts/clean.sh --sim        # Clean simulation files only
#   ./scripts/clean.sh --synth      # Clean synthesis files only
#   ./scripts/clean.sh --dry-run    # Preview what would be deleted
#   ./scripts/clean.sh --help
#
# Exit Codes:
#   0 — Cleanup successful
#   1 — Error during cleanup
# ==============================================================================

set -uo pipefail

# ==============================================================================
# Configuration
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SIM_DIR="${PROJECT_ROOT}/sim"
SYNTH_DIR="${PROJECT_ROOT}/synth"

# Default parameters
CLEAN_SIM=1
CLEAN_SYNTH=1
DRY_RUN=0
FORCE=0

# Counters
FILES_REMOVED=0
DIRS_REMOVED=0
BYTES_FREED=0

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

info()    { echo -e "${CYAN}[CLEAN]${NC} $*"; }
success() { echo -e "${GREEN}[CLEAN]${NC} $*"; }
warn()    { echo -e "${YELLOW}[CLEAN]${NC} $*"; }
error()   { echo -e "${RED}[CLEAN]${NC} $*"; }

# ==============================================================================
# Usage / Help
# ==============================================================================
print_usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} $(basename "$0") [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --sim         Clean simulation files only"
    echo "  --synth       Clean synthesis files only"
    echo "  --all         Clean everything (default)"
    echo "  --dry-run     Preview what would be deleted (no actual deletion)"
    echo "  --force       Skip confirmation prompt"
    echo "  --help        Show this help message"
    echo ""
    echo "What gets cleaned:"
    echo "  Simulation:"
    echo "    sim/work/          QuestaSim work library"
    echo "    sim/results/       Simulation logs, UCDBs, WLFs"
    echo "    sim/cov_html/      HTML coverage reports"
    echo "    sim/merged.ucdb    Merged coverage database"
    echo "    sim/*.vcd          VCD waveform files"
    echo "    sim/transcript     QuestaSim transcript"
    echo "    sim/lint_report.txt Verilator lint report"
    echo ""
    echo "  Synthesis:"
    echo "    synth/reports/     Vivado synthesis reports"
    echo "    synth/.Xil/        Vivado temp directory"
    echo "    synth/*.log        Vivado log files"
    echo "    synth/*.jou        Vivado journal files"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0")                # Clean everything"
    echo "  $(basename "$0") --sim          # Clean sim only"
    echo "  $(basename "$0") --dry-run      # Preview cleanup"
    echo ""
}

# ==============================================================================
# Argument Parsing
# ==============================================================================
parse_args() {
    # If specific targets are given, disable the defaults
    local specific_target=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sim)
                specific_target=1
                CLEAN_SIM=1
                CLEAN_SYNTH=0
                shift
                ;;
            --synth)
                specific_target=1
                CLEAN_SIM=0
                CLEAN_SYNTH=1
                shift
                ;;
            --all)
                CLEAN_SIM=1
                CLEAN_SYNTH=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

# ==============================================================================
# Safe Remove Helpers
# ==============================================================================
# These wrappers handle dry-run mode and track statistics.
# ==============================================================================

# Remove a file
remove_file() {
    local path="$1"

    if [[ -f "${path}" ]]; then
        local size
        size=$(stat -f%z "${path}" 2>/dev/null || stat -c%s "${path}" 2>/dev/null || echo 0)
        BYTES_FREED=$((BYTES_FREED + size))
        FILES_REMOVED=$((FILES_REMOVED + 1))

        if [[ ${DRY_RUN} -eq 1 ]]; then
            echo -e "    ${DIM}[dry-run]${NC} rm  ${path}"
        else
            rm -f "${path}"
            echo -e "    ${DIM}removed${NC}  ${path}"
        fi
    fi
}

# Remove files matching a glob pattern
remove_glob() {
    local dir="$1"
    local pattern="$2"

    if [[ -d "${dir}" ]]; then
        while IFS= read -r -d '' file; do
            remove_file "${file}"
        done < <(find "${dir}" -maxdepth 1 -name "${pattern}" -type f -print0 2>/dev/null)
    fi
}

# Remove a directory recursively
remove_dir() {
    local path="$1"

    if [[ -d "${path}" ]]; then
        local count
        count=$(find "${path}" -type f 2>/dev/null | wc -l)
        local size
        size=$(du -sb "${path}" 2>/dev/null | cut -f1 || echo 0)
        BYTES_FREED=$((BYTES_FREED + size))
        FILES_REMOVED=$((FILES_REMOVED + count))
        DIRS_REMOVED=$((DIRS_REMOVED + 1))

        if [[ ${DRY_RUN} -eq 1 ]]; then
            echo -e "    ${DIM}[dry-run]${NC} rm -rf  ${path}/ (${count} files)"
        else
            rm -rf "${path}"
            echo -e "    ${DIM}removed${NC}  ${path}/ (${count} files)"
        fi
    fi
}

# ==============================================================================
# Format Bytes for Display
# ==============================================================================
format_bytes() {
    local bytes=$1

    if [[ ${bytes} -ge 1073741824 ]]; then
        echo "$(awk "BEGIN { printf \"%.2f GB\", ${bytes}/1073741824 }")"
    elif [[ ${bytes} -ge 1048576 ]]; then
        echo "$(awk "BEGIN { printf \"%.2f MB\", ${bytes}/1048576 }")"
    elif [[ ${bytes} -ge 1024 ]]; then
        echo "$(awk "BEGIN { printf \"%.2f KB\", ${bytes}/1024 }")"
    else
        echo "${bytes} bytes"
    fi
}

# ==============================================================================
# Clean Simulation Artifacts
# ==============================================================================
clean_sim() {
    info "Cleaning simulation artifacts..."
    echo ""

    # Work library
    remove_dir "${SIM_DIR}/work"

    # Simulation results
    remove_dir "${SIM_DIR}/results"

    # Coverage HTML report
    remove_dir "${SIM_DIR}/cov_html"

    # Merged coverage database
    remove_file "${SIM_DIR}/merged.ucdb"

    # VCD waveform files
    remove_glob "${SIM_DIR}" "*.vcd"

    # QuestaSim transcript & WLF
    remove_file "${SIM_DIR}/transcript"
    remove_file "${SIM_DIR}/vsim.wlf"
    remove_file "${SIM_DIR}/modelsim.ini"

    # Lint report
    remove_file "${SIM_DIR}/lint_report.txt"
    remove_file "${SIM_DIR}/coverage_summary.txt"

    echo ""
}

# ==============================================================================
# Clean Synthesis Artifacts
# ==============================================================================
clean_synth() {
    info "Cleaning synthesis artifacts..."
    echo ""

    # Vivado reports
    remove_dir "${SYNTH_DIR}/reports"

    # Vivado temp directory
    remove_dir "${SYNTH_DIR}/.Xil"

    # Vivado project files
    remove_glob "${SYNTH_DIR}" "*.log"
    remove_glob "${SYNTH_DIR}" "*.jou"
    remove_glob "${SYNTH_DIR}" "*.str"
    remove_glob "${SYNTH_DIR}" "*.dcp"

    # Vivado generated project
    remove_dir "${SYNTH_DIR}/apb_project"
    remove_dir "${SYNTH_DIR}/apb_project.runs"
    remove_dir "${SYNTH_DIR}/apb_project.srcs"
    remove_dir "${SYNTH_DIR}/apb_project.cache"
    remove_dir "${SYNTH_DIR}/apb_project.hw"

    echo ""
}

# ==============================================================================
# Confirmation Prompt
# ==============================================================================
confirm_cleanup() {
    if [[ ${FORCE} -eq 1 || ${DRY_RUN} -eq 1 ]]; then
        return 0
    fi

    local targets=""
    [[ ${CLEAN_SIM} -eq 1 ]]   && targets="${targets} simulation"
    [[ ${CLEAN_SYNTH} -eq 1 ]] && targets="${targets} synthesis"

    echo ""
    warn "This will permanently delete${targets} artifacts."
    echo -n "  Continue? [y/N] "
    read -r response

    case "${response}" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        *)
            info "Cancelled."
            exit 0
            ;;
    esac
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     AMBA APB Protocol — Project Cleaner                  ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    parse_args "$@"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        warn "DRY-RUN MODE: No files will actually be deleted."
        echo ""
    fi

    # Show what will be cleaned
    local targets=""
    [[ ${CLEAN_SIM} -eq 1 ]]   && targets="${targets} [simulation]"
    [[ ${CLEAN_SYNTH} -eq 1 ]] && targets="${targets} [synthesis]"
    info "Targets:${targets}"
    echo ""

    # Confirm
    confirm_cleanup

    # Run cleanup
    [[ ${CLEAN_SIM} -eq 1 ]]   && clean_sim
    [[ ${CLEAN_SYNTH} -eq 1 ]] && clean_synth

    # Summary
    local freed
    freed=$(format_bytes ${BYTES_FREED})

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              Cleanup Summary                             ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    printf "║  Files removed       : %-6d                             ║\n" ${FILES_REMOVED}
    printf "║  Directories removed : %-6d                             ║\n" ${DIRS_REMOVED}
    printf "║  Space freed         : %-12s                       ║\n" "${freed}"
    echo "╠══════════════════════════════════════════════════════════╣"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        echo "║    DRY RUN — nothing was actually deleted               ║"
        echo "║    Run without --dry-run to perform cleanup              ║"
    else
        echo "║    Cleanup complete                                      ║"
    fi

    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

main "$@"
