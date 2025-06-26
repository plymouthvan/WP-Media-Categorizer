#!/bin/bash

# WP Media Categorizer - Dependency Installation Script
# Sets up Python environment and checks for required dependencies

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'  # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ${NC} $*"
}

log_success() {
    echo -e "${GREEN}✓${NC} $*"
}

log_error() {
    echo -e "${RED}✗${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $*"
}

# Check if Python 3 is available
check_python() {
    log_info "Checking Python 3 availability..."
    
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 is required but not found"
        echo
        echo "Please install Python 3.8+ first:"
        echo "  macOS: brew install python3"
        echo "  Ubuntu/Debian: sudo apt-get install python3 python3-pip python3-venv"
        echo "  Or download from: https://www.python.org/downloads/"
        exit 1
    fi
    
    local python_version=$(python3 --version 2>&1 | cut -d' ' -f2)
    log_success "Python 3 found: $python_version"
}

# Ask user about virtual environment setup
ask_venv_setup() {
    echo
    echo -e "${BOLD}Virtual Environment Setup${NC}"
    echo "A Python virtual environment isolates dependencies and prevents conflicts."
    echo
    read -p "Would you like to set up a Python virtual environment in ./venv? (Y/n): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        return 1  # User declined
    else
        return 0  # User accepted (default)
    fi
}

# Set up virtual environment and install PyYAML
setup_venv() {
    log_info "Creating Python virtual environment..."
    
    if ! python3 -m venv venv; then
        log_error "Failed to create virtual environment"
        echo
        echo "This might be due to:"
        echo "  - Missing python3-venv package (install with: sudo apt-get install python3-venv)"
        echo "  - Permission issues in current directory"
        echo "  - Insufficient disk space"
        exit 1
    fi
    
    log_success "Virtual environment created in ./venv"
    
    # Activate virtual environment
    log_info "Activating virtual environment..."
    source venv/bin/activate
    
    # Install Python dependencies
    log_info "Installing Python dependencies in virtual environment..."
    if ! pip install pyyaml pymysql; then
        log_error "Failed to install Python dependencies in virtual environment"
        echo
        echo "This might be due to:"
        echo "  - Network connectivity issues"
        echo "  - Pip not available in virtual environment"
        echo "  - Permission issues"
        exit 1
    fi
    
    log_success "Python dependencies (PyYAML, pymysql) installed successfully in virtual environment"
    return 0
}

# Install Python dependencies globally
install_global_dependencies() {
    log_info "Installing Python dependencies globally..."
    log_warning "Installing globally - this may affect system Python packages"
    
    if ! python3 -m pip install pyyaml pymysql; then
        log_error "Failed to install Python dependencies globally"
        echo
        echo "This might be due to:"
        echo "  - Permission issues (try: python3 -m pip install --user pyyaml pymysql)"
        echo "  - Missing pip (install with: python3 -m ensurepip --upgrade)"
        echo "  - System package management restrictions"
        echo
        echo "Consider using a virtual environment instead for better isolation."
        exit 1
    fi
    
    log_success "Python dependencies (PyYAML, pymysql) installed globally"
}

# Check for optional dependencies
check_optional_deps() {
    log_info "Checking optional dependencies..."
    
    local missing_deps=()
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v yq &> /dev/null; then
        missing_deps+=("yq")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_warning "Optional dependencies missing: ${missing_deps[*]}"
        echo
        echo "These are required for the Python preprocessor mode."
        echo "Install with:"
        
        # Detect platform and provide appropriate install command
        if [[ "$OSTYPE" == "darwin"* ]]; then
            echo "  brew install ${missing_deps[*]}"
        elif command -v apt-get &> /dev/null; then
            echo "  sudo apt-get install ${missing_deps[*]}"
        elif command -v yum &> /dev/null; then
            echo "  sudo yum install ${missing_deps[*]}"
        else
            echo "  (install method depends on your system)"
        fi
        
        echo
        echo "You can re-run this script after installing them to verify setup."
        return 1
    else
        log_success "All optional dependencies found: jq, yq"
        return 0
    fi
}

# Show post-installation instructions
show_instructions() {
    local used_venv="$1"
    local missing_optional="$2"
    
    echo
    echo -e "${BOLD}${GREEN}✅ Setup Complete!${NC}"
    echo
    echo -e "${BOLD}Next steps:${NC}"
    
    if [[ "$used_venv" == "true" ]]; then
        echo "1. Activate the virtual environment:"
        echo "   ${BLUE}source venv/bin/activate${NC}"
        echo
        echo "2. Run the script:"
    else
        echo "1. Run the script:"
    fi
    
    echo "   ${BLUE}python preprocess_media.py --limit=5 --verbose${NC}"
    echo "   ${BLUE}python apply_terms_direct.py --dry-run --verbose${NC}"
    echo
    echo "3. For production use:"
    echo "   ${BLUE}python preprocess_media.py${NC}"
    echo "   ${BLUE}python apply_terms_direct.py${NC}"
    echo
    
    echo -e "${BOLD}Dependencies status:${NC}"
    echo -e "${GREEN}✅${NC} Python 3 and PyYAML"
    
    if [[ "$missing_optional" == "true" ]]; then
        echo -e "${YELLOW}⚠️${NC}  jq/yq missing - required for fast preprocessing mode"
        echo "   You can still use legacy mode with: ${BLUE}--no-preprocess${NC}"
    else
        echo -e "${GREEN}✅${NC} jq and yq (fast preprocessing enabled)"
    fi
    
    echo
    echo -e "${BOLD}Note:${NC} If you install missing tools later, re-run ${BLUE}./install-deps.sh${NC} to verify everything is in place."
    
    if [[ "$used_venv" == "true" ]]; then
        echo
        echo -e "${BOLD}Remember:${NC} Activate the virtual environment before each use:"
        echo "   ${BLUE}source venv/bin/activate${NC}"
    fi
}

# Main execution
main() {
    echo -e "${BOLD}WP Media Categorizer - Dependency Setup${NC}"
    echo "========================================"
    echo
    
    # Check Python availability
    check_python
    
    # Ask about virtual environment
    local used_venv="false"
    if ask_venv_setup; then
        setup_venv
        used_venv="true"
    else
        echo
        log_info "Skipping virtual environment setup"
        install_global_dependencies
    fi
    
    # Check optional dependencies
    local missing_optional="false"
    if ! check_optional_deps; then
        missing_optional="true"
    fi
    
    # Show final instructions
    show_instructions "$used_venv" "$missing_optional"
}

# Execute main function
main "$@"
