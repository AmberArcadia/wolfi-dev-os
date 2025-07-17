#!/bin/bash

# Dependency Rebuild Check Script
# Detects when core packages are updated and generates commands to rebuild dependents

set -euo pipefail

# Configuration
DEFAULT_SHARD_SIZE=25
REPO_BASE_DIR="${REPO_BASE_DIR:-/home/amber-arcadia/Documents/GitRepos}"
REPOS=("wolfi-dev-os" "enterprise-packages" "extra-packages")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --shard SIZE     Number of packages to bump per PR (default: $DEFAULT_SHARD_SIZE)"
    echo "  --package NAME   Check specific package instead of detecting changes"
    echo "  --help           Show this help message"
    echo ""
    echo "Example:"
    echo "  $0                    # Auto-detect changed core packages"
    echo "  $0 --package perl     # Check perl dependencies"
    echo "  $0 --shard 50         # Use 50 packages per PR"
}

log() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

# Check if wolfictl is available
check_wolfictl() {
    if ! command -v wolfictl &> /dev/null; then
        error "wolfictl is not installed or not in PATH"
        exit 1
    fi
}

# Get list of changed packages from git diff
get_changed_packages() {
    local changed_files
    changed_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || git diff --name-only HEAD 2>/dev/null || echo "")
    
    if [[ -z "$changed_files" ]]; then
        warn "No changes detected in git diff"
        return 0
    fi
    
    # Extract package names from changed .yaml files
    echo "$changed_files" | grep '\.yaml$' | sed 's/\.yaml$//' | sort -u
}

# Check if a package has significant dependencies (threshold-based)
has_significant_dependencies() {
    local package="$1"
    local dep_count="$2"
    # Consider any package with 5+ dependencies as significant
    # This replaces the hardcoded core package list
    [[ "$dep_count" -ge 5 ]]
}

# Get dependencies for a package across all repos
get_dependencies() {
    local package="$1"
    local temp_file
    temp_file=$(mktemp)
    
    log "Checking dependencies for $package across all repos"
    
    # Build directory arguments for wolfictl (all repos)
    local repo_args=()
    for repo in "${REPOS[@]}"; do
        local repo_path="$REPO_BASE_DIR/$repo"
        if [[ -d "$repo_path" ]]; then
            repo_args+=("-d" "$repo_path")
        fi
    done
    
    # Get dependencies using wolfictl with skip-failures
    if ! wolfictl dot "$package" --show-dependents "${repo_args[@]}" --skip-failures 2>/dev/null | \
        grep -F -- "-> \"$package-" | \
        grep -o '"[^"]*"' | \
        sed 's/"//g' | \
        grep -v "^$package-" | \
        sort -u > "$temp_file"; then
        warn "Failed to get dependencies for $package"
        rm -f "$temp_file"
        return 1
    fi
    
    # Return unique dependencies
    local deps
    deps=$(cat "$temp_file" | head -1000) # Limit to prevent huge outputs
    rm -f "$temp_file"
    
    if [[ -n "$deps" ]]; then
        echo "$deps"
    fi
}

# Extract package name from dependency line (remove version info)
extract_package_name() {
    local dep="$1"
    # Remove version numbers and extract base package name
    echo "$dep" | sed 's/-[0-9].*//' | sed 's/-r[0-9].*//'
}

# Generate wolfictl bump commands for a set of packages
generate_bump_commands() {
    local repo="$1"
    local packages="$2"
    local shard_size="$3"
    local shard_num="$4"
    local total_shards="$5"
    
    local repo_path="$REPO_BASE_DIR/$repo"
    local branch_name="dependency-rebuild-${repo}-shard-${shard_num}"
    
    if [[ -z "$packages" ]]; then
        return 0
    fi
    
    local package_count
    package_count=$(echo "$packages" | wc -w)
    
    echo "# Shard $shard_num/$total_shards for $repo ($package_count packages)"
    echo "cd $repo_path"
    echo "git checkout -b $branch_name"
    echo ""
    
    # Generate wolfictl bump command
    echo "# Bump package epochs to trigger rebuilds"
    echo "wolfictl bump $packages"
    echo ""
    
    # Generate git commands
    echo "# Commit changes"
    echo "git add ."
    echo "git commit -m \"Bump epochs for dependency rebuild (shard $shard_num/$total_shards)\""
    echo ""
    
    # Generate PR command
    echo "# Create pull request"
    echo "git push origin $branch_name"
    echo "gh pr create --title \"Dependency rebuild for $repo (shard $shard_num/$total_shards)\" --body \"Automated dependency rebuild triggered by core package update. This PR bumps epochs for packages that need to be rebuilt.\""
    echo ""
}

# Main function
main() {
    local shard_size="$DEFAULT_SHARD_SIZE"
    local target_package=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --shard)
                shard_size="$2"
                shift 2
                ;;
            --package)
                target_package="$2"
                shift 2
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    check_wolfictl
    
    log "Starting dependency rebuild check..."
    
    # Determine which packages to check
    local packages_to_check=()
    if [[ -n "$target_package" ]]; then
        packages_to_check=("$target_package")
        log "Checking specific package: $target_package"
    else
        log "Detecting changed packages..."
        local changed_packages
        changed_packages=$(get_changed_packages)
        
        if [[ -z "$changed_packages" ]]; then
            log "No package changes detected"
            exit 0
        fi
        
        # Check all changed packages for dependencies
        while IFS= read -r package; do
            if [[ -n "$package" ]]; then
                packages_to_check+=("$package")
                log "Found changed package: $package"
            fi
        done <<< "$changed_packages"
        
        if [[ ${#packages_to_check[@]} -eq 0 ]]; then
            log "No package changes detected"
            exit 0
        fi
    fi
    
    # Check for dependencies across all repos
    local all_affected_packages=()
    for package in "${packages_to_check[@]}"; do
        local deps
        deps=$(get_dependencies "$package")
        
        if [[ -n "$deps" ]]; then
            local dep_count
            dep_count=$(echo "$deps" | wc -l)
            log "Found $dep_count dependencies for $package"
            
            # Extract package names and determine which repo they belong to
            while IFS= read -r dep; do
                local pkg_name
                pkg_name=$(extract_package_name "$dep")
                
                if [[ -n "$pkg_name" ]]; then
                    # Check which repo contains this package
                    for repo in "${REPOS[@]}"; do
                        local repo_path="$REPO_BASE_DIR/$repo"
                        if [[ -d "$repo_path" && -f "$repo_path/$pkg_name.yaml" ]]; then
                            all_affected_packages+=("$repo:$pkg_name")
                            break
                        fi
                    done
                fi
            done <<< "$deps"
        fi
    done
    
    # Remove duplicates and sort
    local unique_packages
    unique_packages=$(printf '%s\n' "${all_affected_packages[@]}" | sort -u)
    
    if [[ -z "$unique_packages" ]]; then
        log "No affected packages found"
        exit 0
    fi
    
    local total_count
    total_count=$(echo "$unique_packages" | wc -l)
    success "Found $total_count packages that need rebuilding"
    
    # Generate commands for each repository
    echo "# ======================================"
    echo "# Dependency Rebuild Commands"
    echo "# ======================================"
    echo ""
    
    for repo in "${REPOS[@]}"; do
        local repo_packages
        repo_packages=$(echo "$unique_packages" | grep "^$repo:" | sed "s/^$repo://" | tr '\n' ' ')
        
        if [[ -z "$repo_packages" ]]; then
            continue
        fi
        
        local package_count
        package_count=$(echo "$repo_packages" | wc -w)
        local total_shards
        total_shards=$(( (package_count + shard_size - 1) / shard_size ))
        
        log "Repository $repo: $package_count packages, $total_shards shards"
        
        for ((shard=1; shard<=total_shards; shard++)); do
            local start_idx=$(( (shard - 1) * shard_size + 1 ))
            local end_idx=$(( shard * shard_size ))
            
            local shard_packages
            shard_packages=$(echo "$repo_packages" | cut -d' ' -f"$start_idx-$end_idx" | xargs)
            
            generate_bump_commands "$repo" "$shard_packages" "$shard_size" "$shard" "$total_shards"
        done
    done
    
    echo "# ======================================"
    echo "# Summary"
    echo "# ======================================"
    echo "# Total packages to rebuild: $total_count"
    echo "# Shard size: $shard_size"
    echo "# Packages that changed: ${packages_to_check[*]}"
    echo ""
    echo "# To execute these commands:"
    echo "# 1. Copy the commands for each repository"
    echo "# 2. Run them in sequence"
    echo "# 3. Review and merge the PRs"
}

# Run main function
main "$@"