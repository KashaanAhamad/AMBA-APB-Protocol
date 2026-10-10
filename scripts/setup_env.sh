#!/bin/bash
# ==============================================================================
# Script:  setup_env.sh
# Purpose: Set up tool paths and environment variables for the AMBA APB project.
#
#          This script must be SOURCED (not executed) to set variables in the
#          current shell session:
#
#            source scripts/setup_env.sh
#            . scripts/setup_env.sh
#
#          It detects the OS, sets tool paths for QuestaSim and Vivado,
#          creates required directories, and validates that tools are accessible.
#
# Usage:
#   source scripts/setup_env.sh           # Setup with default paths
#   source scripts/setup_env.sh --check   # Setup + validate all tools exist
#   source scripts/setup_env.sh --help    # Show help
#
# After sourcing, the following variables are available:
#   $PROJECT_ROOT    — Root of the AMBA APB project
#   $RTL_DIR         — RTL source directory
#   $TB_DIR          — Testbench source directory
#   $SIM_DIR         — Simulation directory
#   $SYNTH_DIR       — Synthesis directory
#   $SCRIPTS_DIR     — Scripts directory
#   $VLIB, $VLOG, $VSIM, $VCOVER  — QuestaSim tool binaries
#   $VIVADO          — Xilinx Vivado binary
#   $VERILATOR       — Verilator binary (for linting)
# ==============================================================================

# ==============================================================================
# Guard: Ensure script is sourced, not executed
# ==============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo ""
    echo "ERROR: This script must be SOURCED, not executed."
    echo ""
    echo "  Correct:   source ${0}"
    echo "             . ${0}"
    echo ""
    echo "  Incorrect: ./${0}"
    echo "             bash ${0}"
    echo ""
    exit 1
fi

# ==============================================================================
# Color Output Helpers
# ==============================================================================
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_CYAN='\033[0;36m'
_BOLD='\033[1m'
_DIM='\033[2m'
_NC='\033[0m'

_info()    { echo -e "${_CYAN}[ENV]${_NC} $*"; }
_success() { echo -e "${_GREEN}[ENV]${_NC} $*"; }
_warn()    { echo -e "${_YELLOW}[ENV]${_NC} $*"; }
_error()   { echo -e "${_RED}[ENV]${_NC} $*"; }

# ==============================================================================
# Help
# ==============================================================================
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo ""
    echo -e "${_BOLD}Usage:${_NC} source $(basename "${BASH_SOURCE[0]}") [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --check    Validate that all tools are found on PATH"
    echo "  --help     Show this help message"
    echo ""
    echo "This script sets up environment variables for the AMBA APB project."
    echo "It must be sourced (not executed) to affect the current shell."
    echo ""
    return 0
fi

CHECK_TOOLS=0
if [[ "${1:-}" == "--check" ]]; then
    CHECK_TOOLS=1
fi

# ==============================================================================
# Detect Project Root
# ==============================================================================
# Locate project root relative to this script's location.
# Expected layout:
#   PROJECT_ROOT/
#   ├── scripts/setup_env.sh   ← this file
#   ├── rtl/
#   ├── tb/
#   ├── sim/
#   └── synth/
# ==============================================================================
SCRIPT_LOCATION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Determine if we're in scripts/ or sim/
if [[ "$(basename "${SCRIPT_LOCATION}")" == "scripts" ]]; then
    export PROJECT_ROOT="$(cd "${SCRIPT_LOCATION}/.." && pwd)"
elif [[ "$(basename "${SCRIPT_LOCATION}")" == "sim" ]]; then
    export PROJECT_ROOT="$(cd "${SCRIPT_LOCATION}/.." && pwd)"
else
    export PROJECT_ROOT="${SCRIPT_LOCATION}"
fi

# ==============================================================================
# Set Project Directory Paths
# ==============================================================================
export RTL_DIR="${PROJECT_ROOT}/rtl"
export TB_DIR="${PROJECT_ROOT}/tb"
export SIM_DIR="${PROJECT_ROOT}/sim"
export SYNTH_DIR="${PROJECT_ROOT}/synth"
export SCRIPTS_DIR="${PROJECT_ROOT}/scripts"

# ==============================================================================
# QuestaSim / ModelSim Tool Paths
# ==============================================================================
# Default paths — update these to match your installation.
# The script first checks if the tools are already on PATH.
# If not, it tries common installation locations.
#
# To override permanently, set these in your ~/.bashrc:
#   export QUESTA_HOME=/opt/questasim/2023.1
# ==============================================================================
if [[ -z "${QUESTA_HOME:-}" ]]; then
    # Try common installation paths
    QUESTA_SEARCH_PATHS=(
        "/opt/questasim"
        "/opt/mentor/questasim"
        "/opt/intelFPGA/questasim"
        "/tools/questasim"
        "/usr/local/questasim"
        "/home/${USER}/questasim"
        "/opt/Siemens/questasim"
        "/opt/mentor/questa/2023.1"
        "/opt/mentor/questa/2022.4"
    )

    for path in "${QUESTA_SEARCH_PATHS[@]}"; do
        if [[ -d "${path}" ]]; then
            export QUESTA_HOME="${path}"
            break
        fi
    done
fi

# Set tool binaries
if [[ -n "${QUESTA_HOME:-}" ]]; then
    export VLIB="${QUESTA_HOME}/bin/vlib"
    export VLOG="${QUESTA_HOME}/bin/vlog"
    export VSIM="${QUESTA_HOME}/bin/vsim"
    export VCOVER="${QUESTA_HOME}/bin/vcover"
    export VOPT="${QUESTA_HOME}/bin/vopt"

    # Add to PATH if not already there
    if [[ ":${PATH}:" != *":${QUESTA_HOME}/bin:"* ]]; then
        export PATH="${QUESTA_HOME}/bin:${PATH}"
    fi
else
    # Assume tools are on PATH already
    export VLIB="${VLIB:-vlib}"
    export VLOG="${VLOG:-vlog}"
    export VSIM="${VSIM:-vsim}"
    export VCOVER="${VCOVER:-vcover}"
    export VOPT="${VOPT:-vopt}"
fi

# ==============================================================================
# Xilinx Vivado Tool Path
# ==============================================================================
if [[ -z "${VIVADO_HOME:-}" ]]; then
    VIVADO_SEARCH_PATHS=(
        "/opt/Xilinx/Vivado/2023.2"
        "/opt/Xilinx/Vivado/2023.1"
        "/opt/Xilinx/Vivado/2022.2"
        "/opt/Xilinx/Vivado/2024.1"
        "/tools/Xilinx/Vivado/2023.2"
        "/home/${USER}/Xilinx/Vivado/2023.2"
    )

    for path in "${VIVADO_SEARCH_PATHS[@]}"; do
        if [[ -d "${path}" ]]; then
            export VIVADO_HOME="${path}"
            break
        fi
    done
fi

if [[ -n "${VIVADO_HOME:-}" ]]; then
    export VIVADO="${VIVADO_HOME}/bin/vivado"

    if [[ ":${PATH}:" != *":${VIVADO_HOME}/bin:"* ]]; then
        export PATH="${VIVADO_HOME}/bin:${PATH}"
    fi
else
    export VIVADO="${VIVADO:-vivado}"
fi

# ==============================================================================
# Verilator Tool Path (Optional — for linting)
# ==============================================================================
if [[ -z "${VERILATOR:-}" ]]; then
    export VERILATOR="verilator"
fi

# ==============================================================================
# License Configuration
# ==============================================================================
# Set license server if not already configured.
# Update this to match your organization's license server.
# ==============================================================================
if [[ -z "${LM_LICENSE_FILE:-}" ]]; then
    # Example: export LM_LICENSE_FILE="1717@license-server.example.com"
    # Uncomment and update the line below for your setup:
    # export LM_LICENSE_FILE="1717@your-license-server"
    :
fi

if [[ -z "${MGLS_LICENSE_FILE:-}" ]]; then
    # Mentor/Siemens license (for QuestaSim)
    # export MGLS_LICENSE_FILE="/opt/mentor/license.dat"
    :
fi

# ==============================================================================
# Create Project Directories (if missing)
# ==============================================================================
mkdir -p "${SIM_DIR}/results"    2>/dev/null
mkdir -p "${SIM_DIR}/cov_html"   2>/dev/null
mkdir -p "${SYNTH_DIR}/reports"  2>/dev/null

# ==============================================================================
# Validate Tool Availability
# ==============================================================================
_check_tool() {
    local tool_name="$1"
    local tool_path="$2"

    if command -v "${tool_path}" &>/dev/null; then
        local version
        # Try to get version (different tools have different flags)
        version=$(${tool_path} --version 2>&1 | head -1 || echo "unknown")
        _success "  ✓ ${tool_name}: $(command -v "${tool_path}")"
        return 0
    else
        _error "  ✗ ${tool_name}: NOT FOUND (expected: ${tool_path})"
        return 1
    fi
}

if [[ ${CHECK_TOOLS} -eq 1 ]]; then
    echo ""
    _info "Validating tool availability..."
    echo ""

    TOOLS_OK=1

    _check_tool "vlib"      "${VLIB}"      || TOOLS_OK=0
    _check_tool "vlog"      "${VLOG}"      || TOOLS_OK=0
    _check_tool "vsim"      "${VSIM}"      || TOOLS_OK=0
    _check_tool "vcover"    "${VCOVER}"    || TOOLS_OK=0
    _check_tool "vivado"    "${VIVADO}"    || TOOLS_OK=0
    _check_tool "verilator" "${VERILATOR}" || _warn "  Verilator not found (optional — lint only)"

    echo ""
    if [[ ${TOOLS_OK} -eq 1 ]]; then
        _success "All required tools found."
    else
        _warn "Some tools are missing. Update paths in this script or set"
        _warn "QUESTA_HOME / VIVADO_HOME environment variables."
    fi
fi

# ==============================================================================
# Print Summary
# ==============================================================================
echo ""
echo -e "${_BOLD}╔══════════════════════════════════════════════════════════╗${_NC}"
echo -e "${_BOLD}║     AMBA APB — Environment Setup Complete                ║${_NC}"
echo -e "${_BOLD}╠══════════════════════════════════════════════════════════╣${_NC}"
echo -e "║  PROJECT_ROOT : ${PROJECT_ROOT}"
echo -e "║  RTL_DIR      : ${RTL_DIR}"
echo -e "║  TB_DIR       : ${TB_DIR}"
echo -e "║  SIM_DIR      : ${SIM_DIR}"
echo -e "║  SYNTH_DIR    : ${SYNTH_DIR}"
echo -e "║  ──────────────────────────────────────────────────────  ║"
echo -e "║  QUESTA_HOME  : ${QUESTA_HOME:-<not set — using PATH>}"
echo -e "║  VIVADO_HOME  : ${VIVADO_HOME:-<not set — using PATH>}"
echo -e "${_BOLD}╚══════════════════════════════════════════════════════════╝${_NC}"
echo ""
_info "Environment ready. You can now run:"
_info "  cd \${SIM_DIR} && make compile"
_info "  cd \${SIM_DIR} && make sim TEST=test_single_write"
echo ""
