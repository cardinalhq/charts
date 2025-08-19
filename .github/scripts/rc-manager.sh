#!/bin/bash

# RC Manager Script
# Handles version management for RC builds and promotions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHART_DIR="${REPO_ROOT}/lakerunner"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
    exit 1
}

# Get current chart version from Chart.yaml
get_current_version() {
    cd "${CHART_DIR}"
    grep "^version:" Chart.yaml | awk '{print $2}' | tr -d '"'
}

# Get current appVersion from Chart.yaml
get_current_app_version() {
    cd "${CHART_DIR}"
    grep "^appVersion:" Chart.yaml | awk '{print $2}' | tr -d '"'
}

# Validate semantic version format
validate_version() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid version format: $version. Expected: X.Y.Z (e.g., 0.4.1)"
    fi
}

# Find next RC number for a given base version
get_next_rc_number() {
    local base_version="$1"
    
    # Get all RC tags for this version and find the highest number
    local highest_rc=$(git tag -l "${base_version}-rc*" 2>/dev/null | \
        sed "s/${base_version}-rc//" | \
        grep -E '^[0-9]+$' | \
        sort -n | \
        tail -1)
    
    if [ -z "$highest_rc" ]; then
        echo "1"
    else
        echo $((highest_rc + 1))
    fi
}

# Check if tag exists
tag_exists() {
    local tag="$1"
    git tag -l | grep -q "^${tag}$"
}

# Build RC version
build_rc() {
    local base_version="$1"
    local rc_number="$2"
    
    validate_version "$base_version"
    
    # If RC number not provided, auto-increment
    if [ -z "$rc_number" ]; then
        rc_number=$(get_next_rc_number "$base_version")
        log_info "Auto-incrementing to RC $rc_number"
    fi
    
    local rc_version="${base_version}-rc${rc_number}"
    local tag_name="lakerunner-${rc_version}"
    
    # Check if this RC already exists
    if tag_exists "$tag_name"; then
        log_error "RC version $rc_version already exists (tag: $tag_name)"
    fi
    
    log_info "Building RC version: $rc_version"
    
    # Trigger GitHub Action
    gh workflow run build-rc.yml \
        -f version="$base_version" \
        -f rc_number="$rc_number"
    
    log_success "RC build triggered for version $rc_version"
    log_info "Monitor progress: gh run list --workflow=build-rc.yml"
    log_info "When ready, promote with: make promote-rc RC=$rc_version"
}

# Promote RC to release
promote_rc() {
    local rc_version="$1"
    
    # Validate RC version format
    if [[ ! "$rc_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-rc[0-9]+$ ]]; then
        log_error "Invalid RC version format: $rc_version. Expected: X.Y.Z-rcN (e.g., 0.4.1-rc1)"
    fi
    
    local base_version=$(echo "$rc_version" | sed 's/-rc[0-9]*$//')
    local rc_tag="lakerunner-${rc_version}"
    local release_tag="lakerunner-${base_version}"
    
    # Check if RC exists
    if ! tag_exists "$rc_tag"; then
        log_error "RC tag $rc_tag does not exist. Available RC tags:"
        git tag -l "lakerunner-*-rc*" | tail -5
        return 1
    fi
    
    # Check if release already exists
    if tag_exists "$release_tag"; then
        log_error "Release tag $release_tag already exists!"
    fi
    
    log_info "Promoting RC $rc_version to release $base_version"
    
    # Trigger GitHub Action
    gh workflow run promote-rc.yml \
        -f rc_version="$rc_version"
    
    log_success "RC promotion triggered for $rc_version → $base_version"
    log_info "Monitor progress: gh run list --workflow=promote-rc.yml"
}

# List available RC versions
list_rcs() {
    log_info "Available RC versions:"
    git tag -l "lakerunner-*-rc*" | sort -V | tail -10
    
    echo ""
    log_info "Available releases:"
    git tag -l "lakerunner-*" | grep -v "rc" | sort -V | tail -10
}

# Show current status
status() {
    local current_version=$(get_current_version)
    local current_app_version=$(get_current_app_version)
    
    echo ""
    log_info "Current Chart Status:"
    echo "  Chart Version: $current_version"
    echo "  App Version: $current_app_version"
    echo ""
    
    log_info "Recent RC versions:"
    git tag -l "lakerunner-*-rc*" | sort -V | tail -5
    
    echo ""
    log_info "Recent releases:"
    git tag -l "lakerunner-*" | grep -v "rc" | sort -V | tail -5
}

# Show help
show_help() {
    cat << EOF
RC Manager - LakeRunner Chart Release Management

Usage: $0 <command> [options]

Commands:
    build-rc <version> [rc_number]   Build RC version (e.g., build-rc 0.4.1)
    promote-rc <rc_version>          Promote RC to release (e.g., promote-rc 0.4.1-rc1)
    list                             List available RC and release versions
    status                           Show current chart status
    help                             Show this help message

Examples:
    $0 build-rc 0.4.1               # Creates 0.4.1-rc1 (or next available RC)
    $0 build-rc 0.4.1 2             # Creates 0.4.1-rc2 specifically
    $0 promote-rc 0.4.1-rc1          # Promotes 0.4.1-rc1 to 0.4.1 release
    $0 list                          # Shows available versions
    $0 status                        # Shows current chart status

Prerequisites:
    - gh CLI tool installed and authenticated
    - Git repository with proper permissions
    - AWS credentials configured for ECR access
EOF
}

# Main script logic
main() {
    case "${1:-help}" in
        "build-rc")
            if [ -z "$2" ]; then
                log_error "Version required. Usage: $0 build-rc <version> [rc_number]"
            fi
            build_rc "$2" "$3"
            ;;
        "promote-rc")
            if [ -z "$2" ]; then
                log_error "RC version required. Usage: $0 promote-rc <rc_version>"
            fi
            promote_rc "$2"
            ;;
        "list")
            list_rcs
            ;;
        "status")
            status
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            log_error "Unknown command: $1"
            show_help
            ;;
    esac
}

# Check prerequisites
if ! command -v gh &> /dev/null; then
    log_error "GitHub CLI (gh) is required but not installed. Install: https://cli.github.com/"
fi

if ! git rev-parse --git-dir > /dev/null 2>&1; then
    log_error "Not in a git repository"
fi

# Change to repo root
cd "$REPO_ROOT"

# Run main function
main "$@"