#!/bin/bash

#############################################################################
# Palette Cluster Profile Cleanup Script
#############################################################################
# This script helps manage unused cluster profile versions by:
# - Discovering unused cluster profile versions (not used by any clusters)
# - Optionally backing up profile versions to JSON before deletion
# - Cleaning up/deleting unused profile versions
#
# Prerequisites:
# - jq (JSON processor)
# - curl
# - SPECTROCLOUD_APIKEY environment variable must be set
#
# Usage:
#   ./cleanup-unused-cluster-profile-versions.sh discover [OPTIONS]
#   ./cleanup-unused-cluster-profile-versions.sh cleanup [OPTIONS]
#
# Options:
#   --api-url <URL>         Palette API URL (default: https://api.spectrocloud.com)
#   --project-uid <UID>     Project UID to scope the search (optional)
#   --backup                Enable backup of profile versions before deletion (cleanup mode only)
#   --no-backup             Disable backup (default in cleanup mode)
#   --output-dir <DIR>      Directory for backups and reports (default: ./output)
#   --help                  Show this help message
#
#############################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
MODE=""
API_URL="https://api.spectrocloud.com"
PROJECT_NAME=""
PROJECT_UID=""
PROFILE_NAME=""
BACKUP_ENABLED=false
CONFIRM_ALL=false
EXPORT_CSV=false
OUTPUT_DIR="./output"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

#############################################################################
# Helper Functions
#############################################################################

print_help() {
    cat << EOF
Palette Cluster Profile Cleanup Script

Usage:
    $0 <mode> [OPTIONS]

Modes:
    analyze     Analyze and report unused cluster profile versions
    cleanup     Delete unused cluster profile versions

Options:
    --api-url <URL>         Palette API URL (default: https://api.spectrocloud.com)
    --project <NAME>        Project name to filter project-scoped profiles (optional)
    --profile <NAME>        Target a specific cluster profile by name (optional)
    --export-csv            Export results to CSV file in output directory
    --backup                Enable backup of profile versions before deletion (cleanup mode only, enabled by default)
    --no-backup             Disable backup in cleanup mode
    --confirm-all           Skip all confirmation prompts (for automation, cleanup mode only)
    --output-dir <DIR>      Directory for backups and reports (default: ./output)
    --debug                 Enable debug output to see API requests
    --help                  Show this help message

Note:
    Cluster profiles can be tenant-scoped (shared) or project-scoped (specific).
    When --project is specified, only project-scoped profiles for that project
    are analyzed. Tenant-scoped profiles are always ignored when filtering by project.
    When --profile is used without --project, it's assumed to be tenant-scoped.

Environment Variables:
    SPECTROCLOUD_APIKEY     Required. Your Palette API key for authentication

Examples:
    # Analyze all cluster profiles (tenant and project-scoped)
    $0 analyze

    # Analyze only project-scoped profiles for a specific project
    $0 analyze --project "My Project"

    # Analyze a specific tenant-scoped profile
    $0 analyze --profile my-cluster-profile

    # Analyze a specific project-scoped profile
    $0 analyze --profile my-cluster-profile --project my-project

    # Cleanup with backup enabled
    $0 cleanup --backup

    # Cleanup specific profile in a project with backup
    $0 cleanup --profile my-cluster-profile --project my-project --backup

EOF
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check for required tools
    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed. Please install jq."
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed. Please install curl."
        exit 1
    fi
    
    # Check for API key
    if [ -z "${SPECTROCLOUD_APIKEY:-}" ]; then
        log_error "SPECTROCLOUD_APIKEY environment variable is not set."
        log_error "Please export your Palette API key: export SPECTROCLOUD_APIKEY='your-api-key'"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

make_api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local project_uid="${4:-}"
    
    local url="${API_URL}/v1/${endpoint}"
    local http_code
    local response
    local temp_file=$(mktemp)
    
    # Debug output
    if [ "${DEBUG:-false}" = "true" ]; then
        log_info "API Request: $method $url"
        if [ -n "$project_uid" ]; then
            log_info "  With ProjectUid header: $project_uid"
        fi
    fi
    
    # Build curl command with headers
    local curl_headers=(-H "Content-Type: application/json" \
                        -H "Accept: application/json" \
                        -H "ApiKey: ${SPECTROCLOUD_APIKEY}")
    
    # Add ProjectUid header if provided
    if [ -n "$project_uid" ]; then
        curl_headers+=(-H "ProjectUid: $project_uid")
    fi
    
    if [ -n "$data" ]; then
        http_code=$(curl -s -w "%{http_code}" -o "$temp_file" -X "$method" "$url" \
            "${curl_headers[@]}" \
            -d "$data")
    else
        http_code=$(curl -s -w "%{http_code}" -o "$temp_file" -X "$method" "$url" \
            "${curl_headers[@]}")
    fi
    
    response=$(cat "$temp_file")
    rm -f "$temp_file"
    
    # Check HTTP status code
    if [ "$http_code" -ge 400 ]; then
        log_error "API request failed with HTTP $http_code: $method $endpoint"
        log_error "URL: $url"
        if [ -n "$response" ]; then
            log_error "Response: $response"
        fi
        return 1
    fi
    
    # HTTP 204 (No Content) is a successful response with no body (common for DELETE)
    if [ "$http_code" -eq 204 ]; then
        echo '{"success": true}'
        return 0
    fi
    
    # Check for empty response (for other status codes)
    if [ -z "$response" ]; then
        log_error "API returned empty response for: $method $endpoint"
        log_error "HTTP Status: $http_code"
        return 1
    fi
    
    # Validate JSON response
    if ! echo "$response" | jq empty 2>/dev/null; then
        log_error "API returned invalid JSON for: $method $endpoint"
        log_error "HTTP Status: $http_code"
        log_error "Response: ${response:0:500}"  # Show first 500 chars
        return 1
    fi
    
    echo "$response"
    return 0
}

get_project_uid_by_name() {
    local project_name="$1"
    
    log_info "Looking up project UID for: $project_name"
    
    local response
    if ! response=$(make_api_request "GET" "projects"); then
        log_error "Failed to fetch projects"
        return 1
    fi
    
    # Find project by name (case-insensitive)
    local uid=$(echo "$response" | jq -r --arg name "$project_name" \
        '.items[]? | select(.metadata.name | ascii_downcase == ($name | ascii_downcase)) | .metadata.uid' | head -1)
    
    if [ -z "$uid" ] || [ "$uid" = "null" ]; then
        log_error "Project not found: $project_name"
        log_info "Available projects:"
        echo "$response" | jq -r '.items[]? | "  - \(.metadata.name) (UID: \(.metadata.uid))"' >&2
        return 1
    fi
    
    log_success "Found project '$project_name' with UID: $uid"
    echo "$uid"
    return 0
}

get_all_cluster_profiles() {
    log_info "Fetching cluster profiles..."
    
    local all_profiles='{"items": []}'
    
    # If a specific profile name is specified, fetch only that profile
    if [ -n "$PROFILE_NAME" ]; then
        log_info "Fetching specific profile: $PROFILE_NAME"
        
        local profile_response
        if [ -n "$PROJECT_UID" ]; then
            # Project-scoped profile
            if ! profile_response=$(make_api_request "GET" "clusterprofiles" "" "$PROJECT_UID"); then
                log_error "Failed to fetch profiles from project"
                return 1
            fi
        else
            # Tenant-scoped profile
            if ! profile_response=$(make_api_request "GET" "clusterprofiles"); then
                log_error "Failed to fetch tenant-scoped profiles"
                return 1
            fi
        fi
        
        # Filter to only the specified profile name
        all_profiles=$(echo "$profile_response" | jq --arg name "$PROFILE_NAME" '{items: [.items[] | select(.metadata.name == $name)]}')
        local profile_count=$(echo "$all_profiles" | jq -r '.items | length' 2>/dev/null || echo "0")
        
        if [ "$profile_count" -eq 0 ]; then
            log_error "Profile '$PROFILE_NAME' not found"
            return 1
        fi
        
        log_info "Found profile: $PROFILE_NAME"
        echo "$all_profiles"
        return 0
    fi
    
    # Fetch tenant-scoped profiles (always included)
    log_info "Fetching tenant-scoped cluster profiles..."
    local tenant_response
    if ! tenant_response=$(make_api_request "GET" "clusterprofiles"); then
        log_error "Failed to fetch tenant-scoped cluster profiles"
        return 1
    fi
    
    local tenant_count=$(echo "$tenant_response" | jq -r '.items | length' 2>/dev/null || echo "0")
    log_info "Retrieved $tenant_count tenant-scoped profiles"
    
    all_profiles="$tenant_response"
    
    # If a specific project is specified, fetch only that project's profiles
    if [ -n "$PROJECT_UID" ]; then
        log_info "Fetching project-scoped cluster profiles for project: $PROJECT_UID..."
        
        local project_response
        local project_count=0
        
        # Use the same endpoint but with ProjectUid header
        if project_response=$(make_api_request "GET" "clusterprofiles" "" "$PROJECT_UID"); then
            project_count=$(echo "$project_response" | jq -r '.items | length' 2>/dev/null || echo "0")
            log_info "Retrieved $project_count project-scoped profiles (using ProjectUid header)"
            
            # Merge the two result sets
            if [ "$project_count" -gt 0 ]; then
                all_profiles=$(echo "$all_profiles $project_response" | jq -s '{"items": (.[0].items + .[1].items)}')
            fi
        else
            log_warning "Failed to fetch project-scoped cluster profiles"
        fi
    else
        # No project specified - fetch profiles from ALL projects
        log_info "Fetching all projects to get project-scoped cluster profiles..."
        
        # Store projects response globally for project name lookup
        PROJECTS_CACHE=""
        
        local projects_response
        if projects_response=$(make_api_request "GET" "projects"); then
            PROJECTS_CACHE="$projects_response"
            local project_count=$(echo "$projects_response" | jq -r '.items | length' 2>/dev/null || echo "0")
            log_info "Found $project_count projects"
            
            # Iterate through each project and fetch its profiles
            for i in $(seq 0 $((project_count - 1))); do
                local project=$(echo "$projects_response" | jq -r ".items[$i]")
                local proj_uid=$(echo "$project" | jq -r '.metadata.uid')
                local proj_name=$(echo "$project" | jq -r '.metadata.name')
                
                log_info "Fetching profiles from project $((i + 1))/$project_count: $proj_name..."
                
                local proj_profiles
                if proj_profiles=$(make_api_request "GET" "clusterprofiles" "" "$proj_uid" 2>/dev/null); then
                    # Filter out tenant-scoped profiles (they're already included in our initial fetch)
                    # Only keep project-scoped profiles, and tag them with the project name
                    local project_only_profiles=$(echo "$proj_profiles" | jq --arg pname "$proj_name" '{items: [.items[] | select(.metadata.annotations.scope != "tenant" and .metadata.annotations.scope != "system") | .metadata.annotations.projectName = $pname]}')
                    local proj_profile_count=$(echo "$project_only_profiles" | jq -r '.items | length' 2>/dev/null || echo "0")
                    
                    if [ "$proj_profile_count" -gt 0 ]; then
                        log_info "  └─ Found $proj_profile_count project-scoped profiles"
                        # Merge profiles from this project
                        all_profiles=$(echo "$all_profiles $project_only_profiles" | jq -s '{"items": (.[0].items + .[1].items)}')
                    else
                        log_info "  └─ No project-scoped profiles found"
                    fi
                else
                    log_warning "  └─ Failed to fetch profiles from project $proj_name"
                fi
            done
            
            log_info "Finished fetching profiles from all projects"
        else
            log_warning "Failed to fetch projects list - only tenant-scoped profiles will be processed"
        fi
    fi
    
    local total_count=$(echo "$all_profiles" | jq -r '.items | length' 2>/dev/null || echo "0")
    log_info "Total profiles to process: $total_count"
    
    echo "$all_profiles"
    return 0
}

get_cluster_profile_details() {
    local profile_uid="$1"
    local profile_scope="$2"
    local profile_project_uid="$3"
    
    # Fetch detailed profile information including usage status
    # For project-scoped profiles, we need to pass the ProjectUid header
    local response
    if [ "$profile_scope" = "project" ] && [ -n "$profile_project_uid" ]; then
        if ! response=$(make_api_request "GET" "clusterprofiles/${profile_uid}" "" "$profile_project_uid"); then
            log_warning "Failed to fetch details for project-scoped profile: $profile_uid"
            return 1
        fi
    else
        if ! response=$(make_api_request "GET" "clusterprofiles/${profile_uid}"); then
            log_warning "Failed to fetch details for profile: $profile_uid"
            return 1
        fi
    fi
    
    echo "$response"
    return 0
}

should_process_profile() {
    local profile="$1"
    
    # Always skip system-scoped profiles
    local scope=$(echo "$profile" | jq -r '.metadata.annotations.scope // "project"' 2>/dev/null)
    if [ "$scope" = "system" ]; then
        echo "false"
        return 0
    fi
    
    # If no project filter specified, process all non-system profiles
    if [ -z "$PROJECT_UID" ]; then
        echo "true"
        return 0
    fi
    
    # When a project is specified, we want to process only project-scoped profiles
    # Tenant-scoped profiles are excluded when filtering by project
    if [ "$scope" = "tenant" ]; then
        # Skip tenant-scoped profiles when filtering by project
        echo "false"
        return 0
    fi
    
    # Process all project-scoped profiles (they've already been filtered by the API)
    echo "true"
    return 0
}

check_profile_usage() {
    local profile="$1"
    
    # Check if this profile has any clusters using it via multiple status fields
    # Don't use -r flag with jq when checking arrays, as we need to preserve JSON structure
    
    # Check inUseClusters (array or null)
    local cluster_count=$(echo "$profile" | jq '.status.inUseClusters | length' 2>/dev/null || echo "0")
    if [ "$cluster_count" -gt 0 ] 2>/dev/null; then
        echo "true"
        return 0
    fi
    
    # Check inUseClusterUids (array or null)
    local uid_count=$(echo "$profile" | jq '.status.inUseClusterUids | length' 2>/dev/null || echo "0")
    if [ "$uid_count" -gt 0 ] 2>/dev/null; then
        echo "true"
        return 0
    fi
    
    # Check inUseClusterTemplates (array, empty means unused)
    local template_count=$(echo "$profile" | jq '.status.inUseClusterTemplates | length' 2>/dev/null || echo "0")
    if [ "$template_count" -gt 0 ] 2>/dev/null; then
        echo "true"
        return 0
    fi
    
    # Default to unused if all fields are null or empty arrays
    echo "false"
    return 0
}

analyze_unused_versions() {
    log_info "Starting analysis of unused cluster profile versions..."
    
    # Get all cluster profiles
    local profiles
    if ! profiles=$(get_all_cluster_profiles); then
        log_error "Cannot proceed without cluster profiles data"
        return 1
    fi
    
    if [ -z "$profiles" ] || [ "$profiles" = "null" ]; then
        log_warning "No cluster profiles found"
        return 0
    fi
    
    log_info "Analyzing cluster profiles for usage..."
    
    local total_checked=0
    local unused_count=0
    local skipped_count=0
    
    # Iterate through each profile and collect table data
    local profile_count=$(echo "$profiles" | jq -r '.items | length' 2>/dev/null || echo "0")
    local table_data=""
    
    for i in $(seq 0 $((profile_count - 1))); do
        local profile_summary=$(echo "$profiles" | jq -r ".items[$i]")
        local profile_uid=$(echo "$profile_summary" | jq -r '.metadata.uid')
        local profile_name=$(echo "$profile_summary" | jq -r '.metadata.name')
        
        # Check if we should process this profile based on project filter
        local should_process=$(should_process_profile "$profile_summary")
        if [ "$should_process" = "false" ]; then
            skipped_count=$((skipped_count + 1))
            if [ "${DEBUG:-false}" = "true" ]; then
                local scope=$(echo "$profile_summary" | jq -r '.metadata.annotations.scope // "project"' 2>/dev/null)
                log_info "Skipping $profile_name (scope: $scope, not in target project)"
            fi
            continue
        fi
        
        # Fetch detailed profile information (list endpoint doesn't include usage status)
        log_info "Analyzing: $profile_name..."
        
        # Determine scope and project UID for the API call
        local profile_scope=$(echo "$profile_summary" | jq -r '.metadata.annotations.scope // "project"')
        local profile_project_uid=""
        
        # If it's project-scoped, we need to know which project
        if [ "$profile_scope" = "project" ]; then
            if [ -n "$PROJECT_UID" ]; then
                # User specified a project, use that
                profile_project_uid="$PROJECT_UID"
            else
                # Try to extract project UID from profile metadata
                profile_project_uid=$(echo "$profile_summary" | jq -r '.metadata.annotations.projectUid // .spec.projectUid // .metadata.projectUid // empty' 2>/dev/null)
            fi
        fi
        
        local profile
        if ! profile=$(get_cluster_profile_details "$profile_uid" "$profile_scope" "$profile_project_uid"); then
            log_warning "  └─ Skipping due to API error"
            continue
        fi
        
        local version=$(echo "$profile" | jq -r '.metadata.version // .spec.version // "1.0.0"')
        local scope=$(echo "$profile" | jq -r '.metadata.annotations.scope // "project"')
        
        # Get project name for project-scoped profiles
        local project_display=""
        if [ "$scope" = "project" ]; then
            if [ -n "$PROJECT_NAME" ]; then
                # User specified a project
                project_display="$PROJECT_NAME"
            else
                # Try to get from cached annotation (set during fetch) or lookup from cache
                project_display=$(echo "$profile_summary" | jq -r '.metadata.annotations.projectName // empty' 2>/dev/null)
                if [ -z "$project_display" ] && [ -n "$PROJECTS_CACHE" ] && [ -n "$profile_project_uid" ]; then
                    project_display=$(echo "$PROJECTS_CACHE" | jq -r ".items[] | select(.metadata.uid == \"$profile_project_uid\") | .metadata.name" 2>/dev/null)
                fi
            fi
            [ -z "$project_display" ] && project_display="unknown"
        else
            project_display="-"
        fi
        
        total_checked=$((total_checked + 1))
        
        # Check if this profile is used by any cluster
        local in_use=$(check_profile_usage "$profile")
        
        local status_label
        if [ "$in_use" = "false" ]; then
            unused_count=$((unused_count + 1))
            status_label="UNUSED"
        else
            status_label="IN USE"
        fi
        
        # Add row to table data
        table_data="${table_data}${profile_name}|${version}|${scope}|${project_display}|${status_label}|${profile_uid}
"
    done
    
    # Display results table
    echo "" >&2
    log_info "========================================" >&2
    log_info "Analysis Results" >&2
    log_info "========================================" >&2
    
    if [ -n "$table_data" ]; then
        # Calculate column widths based on actual data
        local max_name=12  # Minimum for "PROFILE NAME"
        local max_version=7  # Minimum for "VERSION"
        local max_scope=5  # Minimum for "SCOPE"
        local max_project=7  # Minimum for "PROJECT"
        local max_uid=24  # Minimum for UID (24 chars)
        
        # Scan data to find max widths
        while IFS='|' read -r name version scope project status uid; do
            [ -n "$name" ] && [ ${#name} -gt $max_name ] && max_name=${#name}
            [ -n "$version" ] && [ ${#version} -gt $max_version ] && max_version=${#version}
            [ -n "$scope" ] && [ ${#scope} -gt $max_scope ] && max_scope=${#scope}
            [ -n "$project" ] && [ ${#project} -gt $max_project ] && max_project=${#project}
            [ -n "$uid" ] && [ ${#uid} -gt $max_uid ] && max_uid=${#uid}
        done <<< "$table_data"
        
        # Add padding
        max_name=$((max_name + 2))
        max_version=$((max_version + 2))
        max_scope=$((max_scope + 2))
        max_project=$((max_project + 2))
        max_uid=$((max_uid + 2))
        
        # Print table header
        printf "\n%-${max_name}s %-${max_version}s %-${max_scope}s %-${max_project}s %-8s %-${max_uid}s\n" "PROFILE NAME" "VERSION" "SCOPE" "PROJECT" "STATUS" "UID" >&2
        printf "%-${max_name}s %-${max_version}s %-${max_scope}s %-${max_project}s %-8s %-${max_uid}s\n" "$(printf '%.0s-' $(seq 1 $max_name))" "$(printf '%.0s-' $(seq 1 $max_version))" "$(printf '%.0s-' $(seq 1 $max_scope))" "$(printf '%.0s-' $(seq 1 $max_project))" "--------" "$(printf '%.0s-' $(seq 1 $max_uid))" >&2
        
        # Sort table data: UNUSED first, then IN USE
        # Print UNUSED profiles first
        echo "$table_data" | grep '|UNUSED|' | while IFS='|' read -r name version scope project status uid; do
            if [ -n "$name" ]; then
                # Format columns first, then apply color
                local status_padded=$(printf "%-8s" "$status")
                printf "%-${max_name}s %-${max_version}s %-${max_scope}s %-${max_project}s \033[0;33m%s\033[0m %-${max_uid}s\n" "$name" "$version" "$scope" "$project" "$status_padded" "$uid" >&2
            fi
        done
        
        # Print IN USE profiles second
        echo "$table_data" | grep '|IN USE|' | while IFS='|' read -r name version scope project status uid; do
            if [ -n "$name" ]; then
                local status_padded=$(printf "%-8s" "$status")
                printf "%-${max_name}s %-${max_version}s %-${max_scope}s %-${max_project}s \033[0;32m%s\033[0m %-${max_uid}s\n" "$name" "$version" "$scope" "$project" "$status_padded" "$uid" >&2
            fi
        done
        
        echo "" >&2
    fi
    
    # Export to CSV if requested
    if [ "$EXPORT_CSV" = "true" ] && [ -n "$table_data" ]; then
        local csv_file="${OUTPUT_DIR}/analyze_${TIMESTAMP}.csv"
        {
            echo "PROFILE_NAME,VERSION,SCOPE,PROJECT,STATUS,UID"
            echo "$table_data" | while IFS='|' read -r name version scope project status uid; do
                if [ -n "$name" ]; then
                    echo "\"$name\",\"$version\",\"$scope\",\"$project\",\"$status\",\"$uid\""
                fi
            done
        } > "$csv_file"
        log_info "CSV export saved to: $csv_file" >&2
    fi
    
    # Summary
    log_info "========================================" >&2
    log_info "Summary" >&2
    log_info "========================================" >&2
    log_info "Total profiles checked: $total_checked" >&2
    log_info "Unused profiles found: $unused_count" >&2
    if [ $skipped_count -gt 0 ]; then
        log_info "Profiles skipped (out of scope): $skipped_count" >&2
    fi
    echo "" >&2
    
    log_success "Analysis complete!"
}

cleanup_unused_versions() {
    log_info "Starting cleanup of unused cluster profile versions..."
    
    mkdir -p "$OUTPUT_DIR"
    local deleted_file="${OUTPUT_DIR}/deleted_profiles_${TIMESTAMP}.txt"
    local deleted_json="${OUTPUT_DIR}/deleted_profiles_${TIMESTAMP}.json"
    
    # Get all cluster profiles
    local profiles
    if ! profiles=$(get_all_cluster_profiles); then
        log_error "Cannot proceed without cluster profiles data"
        return 1
    fi
    
    if [ -z "$profiles" ] || [ "$profiles" = "null" ]; then
        log_warning "No cluster profiles found"
        return 0
    fi
    
    log_info "Analyzing and cleaning up unused cluster profiles..."
    
    local deleted_profiles='[]'
    local total_checked=0
    local deleted_count=0
    local skipped_count=0
    local table_data=""
    
    local profile_count=$(echo "$profiles" | jq -r '.items | length' 2>/dev/null || echo "0")
    
    for i in $(seq 0 $((profile_count - 1))); do
        local profile_summary=$(echo "$profiles" | jq -r ".items[$i]")
        local profile_uid=$(echo "$profile_summary" | jq -r '.metadata.uid')
        local profile_name=$(echo "$profile_summary" | jq -r '.metadata.name')
        
        # Check if we should process this profile based on project filter
        local should_process=$(should_process_profile "$profile_summary")
        if [ "$should_process" = "false" ]; then
            skipped_count=$((skipped_count + 1))
            if [ "${DEBUG:-false}" = "true" ]; then
                local scope=$(echo "$profile_summary" | jq -r '.metadata.annotations.scope // "project"' 2>/dev/null)
                log_info "Skipping $profile_name (scope: $scope, not in target project)"
            fi
            continue
        fi
        
        # Fetch detailed profile information (list endpoint doesn't include usage status)
        log_info "Checking: $profile_name (UID: $profile_uid)"
        
        # Determine scope and project UID for the API call
        local profile_scope=$(echo "$profile_summary" | jq -r '.metadata.annotations.scope // "project"')
        local profile_project_uid=""
        
        # If it's project-scoped, we need to know which project
        if [ "$profile_scope" = "project" ]; then
            if [ -n "$PROJECT_UID" ]; then
                # User specified a project, use that
                profile_project_uid="$PROJECT_UID"
            else
                # Try to extract project UID from profile metadata
                profile_project_uid=$(echo "$profile_summary" | jq -r '.metadata.annotations.projectUid // .spec.projectUid // .metadata.projectUid // empty' 2>/dev/null)
            fi
        fi
        
        local profile
        if ! profile=$(get_cluster_profile_details "$profile_uid" "$profile_scope" "$profile_project_uid"); then
            log_warning "  └─ Skipping due to API error"
            continue
        fi
        
        local version=$(echo "$profile" | jq -r '.metadata.version // .spec.version // "1.0.0"')
        local scope=$(echo "$profile" | jq -r '.metadata.annotations.scope // "project"')
        
        # Get project name for project-scoped profiles
        local project_display=""
        if [ "$scope" = "project" ]; then
            if [ -n "$PROJECT_NAME" ]; then
                # User specified a project
                project_display="$PROJECT_NAME"
            else
                # Try to get from cached annotation (set during fetch) or lookup from cache
                project_display=$(echo "$profile_summary" | jq -r '.metadata.annotations.projectName // empty' 2>/dev/null)
                if [ -z "$project_display" ] && [ -n "$PROJECTS_CACHE" ] && [ -n "$profile_project_uid" ]; then
                    project_display=$(echo "$PROJECTS_CACHE" | jq -r ".items[] | select(.metadata.uid == \"$profile_project_uid\") | .metadata.name" 2>/dev/null)
                fi
            fi
            [ -z "$project_display" ] && project_display="unknown"
        else
            project_display="-"
        fi
        
        total_checked=$((total_checked + 1))
        
        # Check if this profile is used by any cluster
        local in_use=$(check_profile_usage "$profile")
        
        local status_label
        local action_label
        if [ "$in_use" = "false" ]; then
            log_warning "Profile: $profile_name (v$version, Scope: $scope, Project: $project_display) - UNUSED"
            
            # Prompt for confirmation unless --confirm-all is specified
            if [ "${CONFIRM_ALL:-false}" != "true" ]; then
                echo ""
                echo -e "\033[1;33m  DELETE THIS PROFILE?\033[0m"
                echo "    Name: $profile_name"
                echo "    Version: $version"
                echo "    Scope: $scope"
                echo "    Project: $project_display"
                echo "    UID: $profile_uid"
                echo ""
                read -p "  Confirm deletion (yes/no): " delete_confirm
                
                if [ "$delete_confirm" != "yes" ]; then
                    log_info "  Skipped by user"
                    status_label="IN USE"
                    action_label="Skipped"
                    
                    # Add row to table data
                    table_data="${table_data}${profile_name}|${version}|${scope}|${project_display}|${status_label}|${action_label}
"
                    continue
                fi
                echo ""
            fi
            
            log_warning "  Deleting profile..."
                
            # Backup if enabled
            if [ "$BACKUP_ENABLED" = true ]; then
                local backup_dir="${OUTPUT_DIR}/backups"
                mkdir -p "$backup_dir"
                local backup_file="${backup_dir}/profile_${profile_name}_v${version}_${TIMESTAMP}.json"
                
                # Use the export endpoint for proper backup
                log_info "  Exporting profile backup..."
                local export_url="${API_URL}/v1/clusterprofiles/${profile_uid}/export"
                local export_headers=(-H "Accept: application/octet-stream" -H "ApiKey: ${SPECTROCLOUD_APIKEY}")
                
                # Add ProjectUid header for project-scoped profiles
                if [ "$scope" = "project" ] && [ -n "$profile_project_uid" ]; then
                    export_headers+=(-H "ProjectUid: $profile_project_uid")
                fi
                
                if curl -s -f -L "${export_headers[@]}" "$export_url" -o "$backup_file"; then
                    log_info "  Backed up to: $backup_file"
                else
                    log_warning "  Failed to export profile backup, using JSON fallback"
                    echo "$profile" | jq '.' > "$backup_file"
                fi
            fi
            
            # Delete the profile
            # For project-scoped profiles, we need to pass the ProjectUid header
            local delete_success=false
            if [ "$scope" = "project" ] && [ -n "$profile_project_uid" ]; then
                if make_api_request "DELETE" "clusterprofiles/${profile_uid}" "" "$profile_project_uid"; then
                    delete_success=true
                fi
            else
                if make_api_request "DELETE" "clusterprofiles/${profile_uid}"; then
                    delete_success=true
                fi
            fi
            
            if [ "$delete_success" = "true" ]; then
                deleted_count=$((deleted_count + 1))
                log_success "  Deleted successfully"
                status_label="DELETED"
                action_label="Deleted"
                
                # Add to deleted list
                deleted_profiles=$(echo "$deleted_profiles" | jq --arg puid "$profile_uid" \
                    --arg pname "$profile_name" \
                    --arg ver "$version" \
                    --argjson pinfo "$profile" \
                    '. += [{
                        profileUid: $puid,
                        profileName: $pname,
                        version: $ver,
                        profileInfo: $pinfo
                    }]')
            else
                log_error "  Failed to delete profile"
                status_label="FAILED"
                action_label="Delete Failed"
            fi
        else
            log_success "Profile: $profile_name (v$version) - IN USE - Skipping"
            status_label="IN USE"
            action_label="Skipped"
        fi
        
        # Add row to table data
        table_data="${table_data}${profile_name}|${version}|${scope}|${project_display}|${status_label}|${action_label}
"
    done
    
    # Display results table
    echo "" >&2
    log_info "========================================" >&2
    log_info "Cleanup Results" >&2
    log_info "========================================" >&2
    
    if [ -n "$table_data" ]; then
        # Calculate column widths based on actual data
        local max_name=12  # Minimum for "PROFILE NAME"
        local max_version=7  # Minimum for "VERSION"
        local max_scope=5  # Minimum for "SCOPE"
        local max_project=7  # Minimum for "PROJECT"
        local max_action=6  # Minimum for "ACTION"
        
        # Scan data to find max widths
        while IFS='|' read -r name version scope project status action; do
            [ -n "$name" ] && [ ${#name} -gt $max_name ] && max_name=${#name}
            [ -n "$version" ] && [ ${#version} -gt $max_version ] && max_version=${#version}
            [ -n "$scope" ] && [ ${#scope} -gt $max_scope ] && max_scope=${#scope}
            [ -n "$project" ] && [ ${#project} -gt $max_project ] && max_project=${#project}
            [ -n "$action" ] && [ ${#action} -gt $max_action ] && max_action=${#action}
        done <<< "$table_data"
        
        # Add padding
        max_name=$((max_name + 2))
        max_version=$((max_version + 2))
        max_scope=$((max_scope + 2))
        max_project=$((max_project + 2))
        max_action=$((max_action + 2))
        
        # Print table header
        printf "\n%-${max_name}s %-${max_version}s %-${max_scope}s %-${max_project}s %-8s %-${max_action}s\n" "PROFILE NAME" "VERSION" "SCOPE" "PROJECT" "STATUS" "ACTION" >&2
        printf "%-${max_name}s %-${max_version}s %-${max_scope}s %-${max_project}s %-8s %-${max_action}s\n" "$(printf '%.0s-' $(seq 1 $max_name))" "$(printf '%.0s-' $(seq 1 $max_version))" "$(printf '%.0s-' $(seq 1 $max_scope))" "$(printf '%.0s-' $(seq 1 $max_project))" "--------" "$(printf '%.0s-' $(seq 1 $max_action))" >&2
        
        # Sort table data: DELETED/UNUSED first, then IN USE, then FAILED
        # Print DELETED profiles first (in red)
        echo "$table_data" | grep '|DELETED|' | while IFS='|' read -r name version scope project status action; do
            if [ -n "$name" ]; then
                local status_padded=$(printf "%-8s" "$status")
                printf "%-${max_name}s %-${max_version}s %-${max_scope}s %-${max_project}s \033[0;31m%s\033[0m %-${max_action}s\n" "$name" "$version" "$scope" "$project" "$status_padded" "$action" >&2
            fi
        done
        
        # Print IN USE profiles second
        echo "$table_data" | grep '|IN USE|' | while IFS='|' read -r name version scope project status action; do
            if [ -n "$name" ]; then
                local status_padded=$(printf "%-8s" "$status")
                printf "%-${max_name}s %-${max_version}s %-${max_scope}s %-${max_project}s \033[0;32m%s\033[0m %-${max_action}s\n" "$name" "$version" "$scope" "$project" "$status_padded" "$action" >&2
            fi
        done
        
        # Print FAILED profiles last
        echo "$table_data" | grep '|FAILED|' | while IFS='|' read -r name version scope project status action; do
            if [ -n "$name" ]; then
                local status_padded=$(printf "%-8s" "$status")
                printf "%-${max_name}s %-${max_version}s %-${max_scope}s %-${max_project}s \033[0;31m%s\033[0m %-${max_action}s\n" "$name" "$version" "$scope" "$project" "$status_padded" "$action" >&2
            fi
        done
        
        echo "" >&2
    fi
    
    # Export to CSV if requested
    if [ "$EXPORT_CSV" = "true" ] && [ -n "$table_data" ]; then
        local csv_file="${OUTPUT_DIR}/cleanup_${TIMESTAMP}.csv"
        {
            echo "PROFILE_NAME,VERSION,SCOPE,PROJECT,STATUS,ACTION"
            echo "$table_data" | while IFS='|' read -r name version scope project status action; do
                if [ -n "$name" ]; then
                    echo "\"$name\",\"$version\",\"$scope\",\"$project\",\"$status\",\"$action\""
                fi
            done
        } > "$csv_file"
        log_info "CSV export saved to: $csv_file" >&2
    fi
    
    # Summary
    log_info "========================================" >&2
    log_info "Summary" >&2
    log_info "========================================" >&2
    log_info "Total profiles checked: $total_checked" >&2
    log_info "Profiles deleted: $deleted_count" >&2
    if [ $skipped_count -gt 0 ]; then
        log_info "Profiles skipped (out of scope): $skipped_count" >&2
    fi
    echo "" >&2
    
    # Generate deletion report
    echo "==================================================================" > "$deleted_file"
    echo "Deleted Cluster Profiles Report" >> "$deleted_file"
    echo "Generated: $(date)" >> "$deleted_file"
    echo "Backup enabled: $BACKUP_ENABLED" >> "$deleted_file"
    echo "==================================================================" >> "$deleted_file"
    echo "" >> "$deleted_file"
    echo "Total profiles checked: $total_checked" >> "$deleted_file"
    echo "Profiles deleted: $deleted_count" >> "$deleted_file"
    echo "" >> "$deleted_file"
    echo "==================================================================" >> "$deleted_file"
    echo "Deleted Profiles:" >> "$deleted_file"
    echo "==================================================================" >> "$deleted_file"
    
    if [ "$deleted_count" -gt 0 ]; then
        echo "$deleted_profiles" | jq -r '.[] | "Profile: \(.profileName) v\(.version)\n  UID: \(.profileUid)\n"' >> "$deleted_file"
        echo "$deleted_profiles" | jq '.' > "$deleted_json"
        
        log_success "Cleanup complete!"
        log_info "Deletion report saved to: $deleted_file"
        log_info "Deletion JSON saved to: $deleted_json"
        
        if [ "$BACKUP_ENABLED" = true ]; then
            log_info "Backups saved to: ${OUTPUT_DIR}/backups/"
        fi
    else
        echo "No unused profiles were deleted." >> "$deleted_file"
        log_success "Cleanup complete! No unused profiles found to delete."
    fi
}

#############################################################################
# Main Script
#############################################################################

main() {
    # Parse command line arguments
    if [ $# -eq 0 ]; then
        log_error "No mode specified"
        print_help
        exit 1
    fi
    
    # Check for help flag first
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        print_help
        exit 0
    fi
    
    MODE="$1"
    shift
    
    # Validate mode
    if [ "$MODE" != "analyze" ] && [ "$MODE" != "cleanup" ]; then
        log_error "Invalid mode: $MODE"
        print_help
        exit 1
    fi
    
    # Parse options
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                print_help
                exit 0
                ;;
            --api-url)
                API_URL="$2"
                shift 2
                ;;
            --project)
                PROJECT_NAME="$2"
                shift 2
                ;;
            --profile)
                PROFILE_NAME="$2"
                shift 2
                ;;
            --export-csv)
                EXPORT_CSV=true
                shift
                ;;
            --backup)
                BACKUP_ENABLED=true
                shift
                ;;
            --no-backup)
                BACKUP_ENABLED=false
                shift
                ;;
            --confirm-all)
                CONFIRM_ALL=true
                shift
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                print_help
                exit 1
                ;;
        esac
    done
    
    # Check prerequisites first
    check_prerequisites
    
    # Set up audit logging - create output directory and log file
    mkdir -p "$OUTPUT_DIR"
    AUDIT_LOG="${OUTPUT_DIR}/audit_${TIMESTAMP}.log"
    
    # Start audit log with header
    {
        echo "========================================================================"
        echo "Palette Cluster Profile Cleanup - Audit Log"
        echo "========================================================================"
        echo "Execution Started: $(date)"
        echo "Mode: $MODE"
        echo "User: $(whoami)"
        echo "Host: $(hostname)"
        echo "API URL: $API_URL"
        echo "========================================================================"
        echo ""
    } >> "$AUDIT_LOG"
    
    # Redirect all output to both console and audit log
    # Strip ANSI color codes when writing to the audit log file
    exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$AUDIT_LOG")) 2>&1
    
    log_info "Audit logging enabled: $AUDIT_LOG"
    
    # Resolve project name to UID if specified
    if [ -n "$PROJECT_NAME" ]; then
        if ! PROJECT_UID=$(get_project_uid_by_name "$PROJECT_NAME"); then
            log_error "Failed to resolve project name to UID"
            exit 1
        fi
    fi
    
    # If profile name is specified, log the context
    if [ -n "$PROFILE_NAME" ]; then
        if [ -n "$PROJECT_NAME" ]; then
            log_info "Targeting profile '$PROFILE_NAME' in project '$PROJECT_NAME'"
        else
            log_info "Targeting tenant-scoped profile '$PROFILE_NAME'"
        fi
    fi
    
    # Enable backups by default in cleanup mode
    if [ "$MODE" = "cleanup" ] && [ "${BACKUP_ENABLED:-unset}" = "unset" ]; then
        BACKUP_ENABLED=true
    fi
    
    # Display configuration
    echo ""
    echo "========================================================================"
    if [ "$MODE" = "cleanup" ]; then
        echo -e "\033[1;31m"
        echo "        ██     ██  █████  ██████  ███    ██ ██ ███    ██  ██████  "
        echo "        ██     ██ ██   ██ ██   ██ ████   ██ ██ ████   ██ ██       "
        echo "        ██  █  ██ ███████ ██████  ██ ██  ██ ██ ██ ██  ██ ██   ███ "
        echo "        ██ ███ ██ ██   ██ ██   ██ ██  ██ ██ ██ ██  ██ ██ ██    ██ "
        echo "         ███ ███  ██   ██ ██   ██ ██   ████ ██ ██   ████  ██████  "
        echo ""
        echo "             CLEANUP MODE - PROFILES WILL BE DELETED!"
        echo -e "\033[0m"
        echo "========================================================================"
    else
        echo "Palette Cluster Profile Cleanup - $MODE Mode"
        echo "========================================================================"
    fi
    echo "API URL: $API_URL"
    if [ -n "$PROJECT_NAME" ]; then
        echo "Project: $PROJECT_NAME (UID: $PROJECT_UID)"
    else
        echo "Project: All projects (tenant and project-scoped profiles)"
    fi
    if [ -n "$PROFILE_NAME" ]; then
        echo "Target Profile: $PROFILE_NAME"
    fi
    if [ "$MODE" = "cleanup" ]; then
        echo "Backup enabled: $BACKUP_ENABLED"
        echo "Confirmation mode: $([ "${CONFIRM_ALL:-false}" = "true" ] && echo "Automatic (--confirm-all)" || echo "Interactive")"
    fi
    echo "Output directory: $OUTPUT_DIR"
    echo "========================================================================"
    echo ""
    
    # Prompt for initial confirmation in cleanup mode
    if [ "$MODE" = "cleanup" ] && [ "${CONFIRM_ALL:-false}" != "true" ]; then
        echo -e "\033[1;31m"
        echo "YOU ARE ABOUT TO DELETE UNUSED CLUSTER PROFILES!"
        echo -e "\033[0m"
        echo ""
        echo "This operation will:"
        echo "  - Analyze cluster profiles to find unused ones"
        echo "  - Prompt for confirmation before deleting EACH profile"
        if [ "$BACKUP_ENABLED" = "true" ]; then
            echo "  - Export and backup each profile before deletion"
        fi
        echo ""
        read -p "Do you want to proceed with cleanup mode? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Cleanup cancelled by user"
            exit 0
        fi
        echo ""
    fi
    
    # Execute based on mode
    case "$MODE" in
        analyze)
            analyze_unused_versions
            ;;
        cleanup)
            cleanup_unused_versions
            ;;
    esac
    
    echo ""
    log_success "Operation completed successfully!"
    
    # Log completion to audit log
    {
        echo ""
        echo "========================================================================"
        echo "Execution Completed: $(date)"
        echo "========================================================================"
    } >> "$AUDIT_LOG" 2>&1 || true
    
    log_info "Full audit log saved to: $AUDIT_LOG"
}

# Run main function
main "$@"

