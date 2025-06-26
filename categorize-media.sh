#!/bin/bash

# Media Categorizer - WordPress Taxonomy Assignment Script
# Assigns taxonomy terms to media attachments based on filename keyword matches
# Requires: wp-cli, yq, bash 3.2+

set -euo pipefail

# Script version and info
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="Media Categorizer"
readonly CONFIG_FILE="config.yml"
readonly TAXONOMY_NAME="media_category"

# Global variables for configuration and data
declare -a MEDIA_IDS=()
declare -a MEDIA_FILENAMES=()
declare -a MEDIA_TITLES=()
declare -a TERM_NAMES=()
declare -a TERM_IDS=()

# Arguments
ARG_APPLY=false
ARG_NO_PROMPT=false
ARG_EXPORT=false
ARG_NO_COLOR=false
ARG_VERBOSE=false
ARG_LIMIT=0
ARG_PREPROCESS=true
ARG_KEEP_TEMP=false

# Configuration variables
CONFIG_WP_PATH=""
CONFIG_TAXONOMY_MODE="all"
CONFIG_BACKUP_ENABLED=false
CONFIG_BACKUP_PATH=""
CONFIG_OUTPUT_CSV_PATH="./logs/media-categorizer-log-\$(date +%F_%H-%M-%S).csv"

# Color codes (disabled with --no-color)
if [[ "${ARG_NO_COLOR}" != "true" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly PURPLE='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly WHITE='\033[1;37m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m'  # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly PURPLE=''
    readonly CYAN=''
    readonly WHITE=''
    readonly BOLD=''
    readonly NC=''
fi

#==============================================================================
# UTILITY FUNCTIONS
#==============================================================================

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

log_verbose() {
    if [[ "${ARG_VERBOSE}" == "true" ]]; then
        echo -e "${CYAN}→${NC} $*"
    fi
}

# Show usage information
show_usage() {
    cat << EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

USAGE:
    $0 [OPTIONS]

DESCRIPTION:
    Assigns taxonomy terms to WordPress media attachments based on filename 
    keyword matches defined in ${CONFIG_FILE}.

OPTIONS:
    --apply           Apply changes to WordPress (default: dry run)
    --no-prompt       Skip interactive prompts (auto-create missing terms)
    --limit=N         Process only the first N matching attachments
    --export          Generate CSV output only, no changes or prompts
    --preprocess      Use Python preprocessor for fast matching (default: true)
    --no-preprocess   Use legacy Bash matching (slower but no Python required)
    --keep-temp       Keep temporary matches.json file for debugging
    --no-color        Disable colored output
    --verbose         Show detailed runtime information
    -h, --help        Show this help message

EXAMPLES:
    $0                    # Dry run (show what would happen)
    $0 --apply            # Apply changes with prompts
    $0 --apply --no-prompt # Apply changes without prompts
    $0 --export           # Generate CSV report only
    $0 --limit=10 --verbose # Process first 10 attachments with details

REQUIREMENTS:
    - WordPress CLI (wp) must be installed and available
    - yq must be installed for YAML parsing
    - Bash 3.2+ is required
    - On macOS with older bash, install newer version: brew install bash

EOF
}

#==============================================================================
# DATA MANAGEMENT FUNCTIONS
#==============================================================================

# Find index of media by ID
find_media_index() {
    local target_id="$1"
    local i
    for i in "${!MEDIA_IDS[@]}"; do
        if [[ "${MEDIA_IDS[$i]}" == "$target_id" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# Add media data
add_media_data() {
    local id="$1" filename="$2" title="$3"
    MEDIA_IDS+=("$id")
    MEDIA_FILENAMES+=("$filename")
    MEDIA_TITLES+=("$title")
}

# Get media filename by ID
get_media_filename() {
    local target_id="$1"
    local index
    if index=$(find_media_index "$target_id"); then
        echo "${MEDIA_FILENAMES[$index]}"
    fi
}

# Find term ID by name
find_term_id() {
    local target_name="$1"
    local i
    for i in "${!TERM_NAMES[@]}"; do
        if [[ "${TERM_NAMES[$i]}" == "$target_name" ]]; then
            echo "${TERM_IDS[$i]}"
            return 0
        fi
    done
    return 1
}

# Check if term exists
term_exists() {
    local term_name="$1"
    find_term_id "$term_name" >/dev/null
}

# Add term to cache
add_term_to_cache() {
    local name="$1" id="$2"
    TERM_NAMES+=("$name")
    TERM_IDS+=("$id")
}

#==============================================================================
# ENVIRONMENT VALIDATION
#==============================================================================

check_bash_version() {
    local bash_version="${BASH_VERSION%%.*}"
    if [[ $bash_version -lt 3 ]]; then
        log_error "Bash 3.2+ is required (current: $BASH_VERSION)"
        log_error "On macOS, install with: brew install bash"
        return 1
    fi
    log_verbose "Bash version: $BASH_VERSION ✓"
}

check_dependencies() {
    local missing_deps=()
    
    if ! command -v wp &> /dev/null; then
        missing_deps+=("wp-cli")
    fi
    
    if ! command -v yq &> /dev/null; then
        missing_deps+=("yq")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        printf '  - %s\n' "${missing_deps[@]}"
        log_error "Install with:"
        for dep in "${missing_deps[@]}"; do
            case $dep in
                "wp-cli") echo "  curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && sudo mv wp-cli.phar /usr/local/bin/wp" ;;
                "yq") echo "  brew install yq  # or download from https://github.com/mikefarah/yq" ;;
            esac
        done
        return 1
    fi
    
    log_verbose "Dependencies: wp-cli, yq ✓"
}

validate_wordpress() {
    if [[ ! -d "$CONFIG_WP_PATH" ]]; then
        log_error "WordPress path does not exist: $CONFIG_WP_PATH"
        return 1
    fi
    
    log_verbose "Testing WordPress connection..."
    if ! (cd "$CONFIG_WP_PATH" && wp core version &> /dev/null); then
        log_error "Cannot connect to WordPress at: $CONFIG_WP_PATH"
        log_error "Ensure wp-cli is configured and WordPress is accessible"
        return 1
    fi
    
    # Check if taxonomy exists
    log_verbose "Checking for taxonomy: $TAXONOMY_NAME"
    local taxonomy_check
    if ! taxonomy_check=$(cd "$CONFIG_WP_PATH" && wp taxonomy get "$TAXONOMY_NAME" --field=name 2>/dev/null); then
        log_error "Taxonomy '${TAXONOMY_NAME}' not found in WordPress"
        log_error "Please register the taxonomy before running this script"
        return 1
    fi
    
    log_verbose "WordPress connection and taxonomy ✓"
}

#==============================================================================
# CONFIGURATION MANAGEMENT
#==============================================================================

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        log_error "Create one based on sample.config.yml"
        return 1
    fi
    
    log_verbose "Loading configuration from $CONFIG_FILE..."
    
    # Validate YAML syntax
    if ! yq eval '.' "$CONFIG_FILE" &> /dev/null; then
        log_error "Invalid YAML syntax in $CONFIG_FILE"
        return 1
    fi
    
    # Load required settings
    CONFIG_WP_PATH=$(yq eval '.settings.wp_path' "$CONFIG_FILE")
    CONFIG_TAXONOMY_MODE=$(yq eval '.settings.apply_taxonomy.mode // "all"' "$CONFIG_FILE")
    CONFIG_BACKUP_ENABLED=$(yq eval '.settings.backup.enabled // false' "$CONFIG_FILE")
    CONFIG_BACKUP_PATH=$(yq eval '.settings.backup.output_path // ""' "$CONFIG_FILE")
    CONFIG_OUTPUT_CSV_PATH=$(yq eval '.settings.output_csv_path // "./logs/media-categorizer-log-$(date +%F_%H-%M-%S).csv"' "$CONFIG_FILE")
    
    log_verbose "Configuration loaded ✓"
}

validate_config() {
    local errors=()
    
    # Required fields
    if [[ -z "$CONFIG_WP_PATH" || "$CONFIG_WP_PATH" == "null" ]]; then
        errors+=("settings.wp_path is required")
    fi
    
    # Validate taxonomy mode
    case "$CONFIG_TAXONOMY_MODE" in
        "all"|"children_only"|"bottom_only") ;;
        *) errors+=("settings.apply_taxonomy.mode must be: all, children_only, or bottom_only") ;;
    esac
    
    # Check if mappings exist
    local mapping_count=$(yq eval '.mappings | length' "$CONFIG_FILE")
    if [[ "$mapping_count" == "0" || "$mapping_count" == "null" ]]; then
        errors+=("No mappings defined in configuration")
    fi
    
    # Report validation errors
    if [[ ${#errors[@]} -gt 0 ]]; then
        log_error "Configuration validation failed:"
        printf '  - %s\n' "${errors[@]}"
        return 1
    fi
    
    log_verbose "Configuration validation ✓"
}

get_csv_output_path() {
    # Expand the $(date) command substitution if present
    local expanded_path=$(eval echo "$CONFIG_OUTPUT_CSV_PATH")
    echo "$expanded_path"
}

ensure_csv_directory() {
    local csv_path="$1"
    local csv_dir=$(dirname "$csv_path")
    
    if [[ ! -d "$csv_dir" ]]; then
        log_verbose "Creating directory: $csv_dir"
        mkdir -p "$csv_dir" || {
            log_error "Failed to create directory: $csv_dir"
            return 1
        }
    fi
}

#==============================================================================
# PYTHON PREPROCESSOR INTERFACE
#==============================================================================

run_python_preprocessor() {
    log_info "Running Python preprocessor..."
    
    # Check if Python 3 is available
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 is required for preprocessing. Install Python 3.8+ or use --no-preprocess"
        return 1
    fi
    
    # Check if preprocess_media.py exists
    if [[ ! -f "preprocess_media.py" ]]; then
        log_error "preprocess_media.py not found. Ensure the Python preprocessor script is in the current directory"
        return 1
    fi
    
    # Build Python command
    local python_args="--config $CONFIG_FILE"
    if [[ $ARG_LIMIT -gt 0 ]]; then
        python_args="$python_args --limit $ARG_LIMIT"
    fi
    if [[ "$ARG_VERBOSE" == "true" ]]; then
        python_args="$python_args --verbose"
    fi
    
    log_verbose "Executing: python3 preprocess_media.py $python_args"
    
    # Run Python preprocessor
    if ! python3 preprocess_media.py $python_args; then
        log_error "Python preprocessor failed"
        return 1
    fi
    
    log_success "Python preprocessing completed"
}

load_matches_from_json() {
    local matches_file="tmp/matches.json"
    
    if [[ ! -f "$matches_file" ]]; then
        log_error "Matches file not found: $matches_file"
        log_error "Python preprocessor may have failed"
        return 1
    fi
    
    # Check if jq is available for JSON parsing
    if ! command -v jq &> /dev/null; then
        log_error "jq is required for JSON parsing. Install with: brew install jq"
        return 1
    fi
    
    log_verbose "Loading matches from: $matches_file"
    
    # Check if matches file is empty or contains empty object
    local match_count=$(jq 'length' "$matches_file" 2>/dev/null || echo "0")
    if [[ "$match_count" == "0" ]]; then
        log_info "No matches found in preprocessor results"
        # Create empty temp files for compatibility with display functions
        TEMP_MATCHES_FILE=$(mktemp)
        TEMP_TERMS_FILE=$(mktemp)
        return 0
    fi
    
    # Load attachment IDs (Bash 3.2 compatible)
    while IFS= read -r id; do
        MEDIA_IDS+=("$id")
    done < <(jq -r 'keys[]' "$matches_file")
    
    # Load corresponding data for each ID
    local i=0
    for id in "${MEDIA_IDS[@]}"; do
        MEDIA_FILENAMES[$i]=$(jq -r --arg id "$id" '.[$id].filename' "$matches_file")
        MEDIA_TITLES[$i]=$(jq -r --arg id "$id" '.[$id].title' "$matches_file")
        ((i++))
    done
    
    # Create temporary files for compatibility with existing display functions
    TEMP_MATCHES_FILE=$(mktemp)
    TEMP_TERMS_FILE=$(mktemp)
    
    # Populate temp files from JSON data
    for id in "${MEDIA_IDS[@]}"; do
        # Get terms for this attachment (Bash 3.2 compatible)
        local terms=()
        while IFS= read -r term; do
            terms+=("$term")
        done < <(jq -r --arg id "$id" '.[$id].terms[]' "$matches_file")
        
        # Create a dummy mapping key for each term (for display compatibility)
        for term in "${terms[@]}"; do
            echo "$id,preprocessed" >> "$TEMP_MATCHES_FILE"
            echo "$id,$term" >> "$TEMP_TERMS_FILE"
        done
    done
    
    log_success "Loaded $match_count attachments with matches from JSON"
}

#==============================================================================
# WORDPRESS INTERFACE
#==============================================================================

get_media_attachments() {
    log_info "Fetching media attachments..."
    
    # Create temp files early for match storage
    TEMP_MATCHES_FILE=$(mktemp)
    TEMP_TERMS_FILE=$(mktemp)
    
    local wp_args="post list --post_type=attachment --format=csv --fields=ID,post_title,guid"
    if [[ $ARG_LIMIT -gt 0 ]]; then
        wp_args="$wp_args --posts_per_page=$ARG_LIMIT"
    fi
    
    local attachment_data
    if ! attachment_data=$(cd "$CONFIG_WP_PATH" && wp $wp_args 2>/dev/null); then
        log_error "Failed to fetch media attachments"
        return 1
    fi
    
    local total_count=0
    local matched_count=0
    
    while IFS=',' read -r id title guid; do
        # Skip header row
        if [[ "$id" == "ID" ]]; then
            continue
        fi
        
        # Extract filename from GUID
        local filename=$(basename "$guid")
        
        # Remove quotes if present
        id=${id//\"/}
        title=${title//\"/}
        filename=${filename//\"/}
        
        ((total_count++))
        
        # NEW: Filter during processing - only store matching attachments
        if has_keyword_matches "$filename"; then
            add_media_data "$id" "$filename" "$title"
            store_matches_for_attachment "$id" "$filename"
            ((matched_count++))
        else
            # Verbose logging for non-matches
            log_verbose "Processing: $filename (ID: $id) - no matches"
        fi
    done <<< "$attachment_data"
    
    log_success "Found $total_count attachments, $matched_count with matches"
    if [[ $matched_count -gt 0 ]]; then
        log_verbose "Sample: ${MEDIA_FILENAMES[0]}"
    fi
}

cache_taxonomy_terms() {
    log_verbose "Caching existing taxonomy terms..."
    
    local term_data
    if ! term_data=$(cd "$CONFIG_WP_PATH" && wp term list "$TAXONOMY_NAME" --format=csv --fields=term_id,name,parent 2>/dev/null); then
        log_error "Failed to fetch taxonomy terms"
        return 1
    fi
    
    local count=0
    while IFS=',' read -r term_id name parent; do
        # Skip header row
        if [[ "$term_id" == "term_id" ]]; then
            continue
        fi
        
        # Remove quotes
        term_id=${term_id//\"/}
        name=${name//\"/}
        parent=${parent//\"/}
        
        add_term_to_cache "$name" "$term_id"
        ((count++))
    done <<< "$term_data"
    
    log_verbose "Cached $count existing terms"
}

create_taxonomy_term() {
    local term_path="$1"
    
    # Parse hierarchical term (e.g., "Wedding > Portraits")
    IFS=' > ' read -ra TERM_PARTS <<< "$term_path"
    local parent_id=""
    
    # Create each level of the hierarchy
    local i
    for i in "${!TERM_PARTS[@]}"; do
        local term_name="${TERM_PARTS[$i]}"
        
        # Skip if term already exists
        if term_exists "$term_name"; then
            parent_id=$(find_term_id "$term_name")
            continue
        fi
        
        # Create the term
        log_verbose "Creating term: $term_name (parent: ${parent_id:-none})"
        
        local wp_args="term create $TAXONOMY_NAME \"$term_name\" --porcelain"
        if [[ -n "$parent_id" ]]; then
            wp_args="$wp_args --parent=$parent_id"
        fi
        
        local new_term_id
        if ! new_term_id=$(cd "$CONFIG_WP_PATH" && wp $wp_args 2>/dev/null); then
            log_error "Failed to create term: $term_name"
            return 1
        fi
        
        # Cache the new term
        add_term_to_cache "$term_name" "$new_term_id"
        parent_id="$new_term_id"
        log_verbose "Created term: $term_name (ID: $new_term_id)"
    done
}

#==============================================================================
# KEYWORD MATCHING ENGINE
#==============================================================================

match_filename() {
    local filename="$1"
    local pattern="$2"
    local is_regex="${3:-false}"
    
    if [[ "$is_regex" == "true" ]]; then
        # Use regex matching (basic regex support in older bash)
        if echo "$filename" | grep -qE "$pattern"; then
            return 0
        fi
    else
        # Use case-insensitive string matching
        local lower_filename=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
        local lower_pattern=$(echo "$pattern" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$lower_filename" == *"$lower_pattern"* ]]; then
            return 0
        fi
    fi
    
    return 1
}

# Check if a filename has any keyword matches (for early filtering)
has_keyword_matches() {
    local filename="$1"
    
    while IFS= read -r mapping_key; do
        local match_pattern=$(yq eval ".mappings.$mapping_key.match" "$CONFIG_FILE")
        local is_regex=$(yq eval ".mappings.$mapping_key.regex // false" "$CONFIG_FILE")
        
        if match_filename "$filename" "$match_pattern" "$is_regex"; then
            return 0  # Found a match
        fi
    done <<< "$(yq eval '.mappings | keys | .[]' "$CONFIG_FILE")"
    
    return 1  # No matches found
}

# Store matches for an attachment (replicates process_keyword_matches behavior)
store_matches_for_attachment() {
    local attachment_id="$1" filename="$2"
    local has_matches=false
    
    log_verbose "Processing: $filename (ID: $attachment_id)"
    
    while IFS= read -r mapping_key; do
        local match_pattern=$(yq eval ".mappings.$mapping_key.match" "$CONFIG_FILE")
        local is_regex=$(yq eval ".mappings.$mapping_key.regex // false" "$CONFIG_FILE")
        
        if match_filename "$filename" "$match_pattern" "$is_regex"; then
            log_verbose "  ✓ Matched keyword: \"$match_pattern\""
            echo "$attachment_id,$mapping_key" >> "$TEMP_MATCHES_FILE"
            has_matches=true
            
            while IFS= read -r term_path; do
                echo "$attachment_id,$term_path" >> "$TEMP_TERMS_FILE"
                log_verbose "    → $term_path"
            done <<< "$(yq eval ".mappings.$mapping_key.terms[]" "$CONFIG_FILE")"
        fi
    done <<< "$(yq eval '.mappings | keys | .[]' "$CONFIG_FILE")"
    
    return 0
}

process_keyword_matches() {
    log_info "Processing keyword matches..."
    
    # All the work is now done during get_media_attachments()
    # This function just reports the pre-computed results
    local processed_count=${#MEDIA_IDS[@]}
    local matched_count=$processed_count  # All stored items are matches now
    
    log_success "Processed $processed_count attachments, $matched_count with matches"
}

#==============================================================================
# OUTPUT AND DISPLAY
#==============================================================================

display_dry_run_table() {
    if [[ ! -f "$TEMP_MATCHES_FILE" || ! -s "$TEMP_MATCHES_FILE" ]]; then
        log_info "No attachments matched any keywords"
        return 0
    fi
    
    echo
    echo "${BOLD}DRY RUN SUMMARY${NC}"
    echo "================================================================================"
    printf "%-8s %-30s %-20s %-30s\n" "ID" "FILENAME" "MATCHED KEYWORDS" "TAXONOMY TERMS"
    echo "================================================================================"
    
    # Group matches by attachment ID
    local current_id=""
    local matches=""
    local terms=""
    
    while IFS=',' read -r attachment_id keyword; do
        if [[ "$attachment_id" != "$current_id" ]]; then
            # Print previous entry if exists
            if [[ -n "$current_id" ]]; then
                local filename=$(get_media_filename "$current_id")
                
                # Truncate long values for display
                if [[ ${#filename} -gt 28 ]]; then
                    filename="${filename:0:25}..."
                fi
                if [[ ${#matches} -gt 18 ]]; then
                    matches="${matches:0:15}..."
                fi
                if [[ ${#terms} -gt 28 ]]; then
                    terms="${terms:0:25}..."
                fi
                
                printf "%-8s %-30s %-20s %-30s\n" "$current_id" "$filename" "$matches" "$terms"
            fi
            
            # Start new entry
            current_id="$attachment_id"
            matches="$keyword"
            
            # Get terms for this attachment
            terms=""
            while IFS=',' read -r term_attachment_id term_path; do
                if [[ "$term_attachment_id" == "$attachment_id" ]]; then
                    if [[ -n "$terms" ]]; then
                        terms="$terms,$term_path"
                    else
                        terms="$term_path"
                    fi
                fi
            done < "$TEMP_TERMS_FILE"
        else
            matches="$matches,$keyword"
        fi
    done < "$TEMP_MATCHES_FILE"
    
    # Print last entry
    if [[ -n "$current_id" ]]; then
        local filename=$(get_media_filename "$current_id")
        
        # Truncate long values for display
        if [[ ${#filename} -gt 28 ]]; then
            filename="${filename:0:25}..."
        fi
        if [[ ${#matches} -gt 18 ]]; then
            matches="${matches:0:15}..."
        fi
        if [[ ${#terms} -gt 28 ]]; then
            terms="${terms:0:25}..."
        fi
        
        printf "%-8s %-30s %-20s %-30s\n" "$current_id" "$filename" "$matches" "$terms"
    fi
    
    echo "================================================================================"
    echo
    log_info "This was a dry run. Use --apply to make changes."
}

generate_csv_log() {
    local mode="$1"  # "apply" or "export"
    local csv_path=$(get_csv_output_path)
    
    # Ensure directory exists
    ensure_csv_directory "$csv_path" || return 1
    
    log_verbose "Writing CSV log to: $csv_path"
    
    # Create CSV header
    echo "attachment_id,filename,matched_keywords,terms_assigned,terms_created,timestamp" > "$csv_path"
    
    if [[ -f "$TEMP_MATCHES_FILE" && -s "$TEMP_MATCHES_FILE" ]]; then
        # Process each attachment with matches
        local current_id=""
        local matches=""
        local terms=""
        
        while IFS=',' read -r attachment_id keyword; do
            if [[ "$attachment_id" != "$current_id" ]]; then
                # Write previous entry if exists
                if [[ -n "$current_id" ]]; then
                    local filename=$(get_media_filename "$current_id")
                    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                    
                    # Escape quotes in CSV fields
                    filename=${filename//\"/\"\"}
                    matches=${matches//\"/\"\"}
                    terms=${terms//\"/\"\"}
                    
                    echo "$current_id,\"$filename\",\"$matches\",\"$terms\",\"\",$timestamp" >> "$csv_path"
                fi
                
                # Start new entry
                current_id="$attachment_id"
                matches="$keyword"
                
                # Get terms for this attachment
                terms=""
                while IFS=',' read -r term_attachment_id term_path; do
                    if [[ "$term_attachment_id" == "$attachment_id" ]]; then
                        if [[ -n "$terms" ]]; then
                            terms="$terms,$term_path"
                        else
                            terms="$term_path"
                        fi
                    fi
                done < "$TEMP_TERMS_FILE"
            else
                matches="$matches,$keyword"
            fi
        done < "$TEMP_MATCHES_FILE"
        
        # Write last entry
        if [[ -n "$current_id" ]]; then
            local filename=$(get_media_filename "$current_id")
            local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            
            # Escape quotes in CSV fields
            filename=${filename//\"/\"\"}
            matches=${matches//\"/\"\"}
            terms=${terms//\"/\"\"}
            
            echo "$current_id,\"$filename\",\"$matches\",\"$terms\",\"\",$timestamp" >> "$csv_path"
        fi
    fi
    
    log_success "Results logged to: $csv_path"
}

#==============================================================================
# MAIN EXECUTION MODES
#==============================================================================

dry_run_mode() {
    log_info "Running in dry run mode..."
    display_dry_run_table
}

export_mode() {
    log_info "Running in export mode (CSV output only)..."
    generate_csv_log "export"
    log_info "Export complete. No changes were made to WordPress."
}

apply_mode() {
    log_info "Running in apply mode..."
    log_warning "Apply mode not fully implemented in this simplified version"
    log_info "This would create backups, terms, and apply taxonomy assignments"
}

#==============================================================================
# ARGUMENT PARSING
#==============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --apply)
                ARG_APPLY=true
                shift
                ;;
            --no-prompt)
                ARG_NO_PROMPT=true
                shift
                ;;
            --export)
                ARG_EXPORT=true
                shift
                ;;
            --no-color)
                ARG_NO_COLOR=true
                shift
                ;;
            --verbose)
                ARG_VERBOSE=true
                shift
                ;;
            --limit=*)
                ARG_LIMIT="${1#*=}"
                if ! [[ "$ARG_LIMIT" =~ ^[0-9]+$ ]]; then
                    log_error "Invalid limit value: $ARG_LIMIT"
                    exit 1
                fi
                shift
                ;;
            --preprocess=*)
                ARG_PREPROCESS="${1#*=}"
                if [[ "$ARG_PREPROCESS" != "true" && "$ARG_PREPROCESS" != "false" ]]; then
                    log_error "Invalid preprocess value: $ARG_PREPROCESS (must be true or false)"
                    exit 1
                fi
                shift
                ;;
            --preprocess)
                ARG_PREPROCESS=true
                shift
                ;;
            --no-preprocess)
                ARG_PREPROCESS=false
                shift
                ;;
            --keep-temp)
                ARG_KEEP_TEMP=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Validate argument combinations
    if [[ "$ARG_EXPORT" == "true" && "$ARG_APPLY" == "true" ]]; then
        log_error "Cannot use --export and --apply together"
        exit 1
    fi
}

#==============================================================================
# CLEANUP
#==============================================================================

cleanup() {
    if [[ -n "${TEMP_MATCHES_FILE:-}" && -f "$TEMP_MATCHES_FILE" ]]; then
        rm -f "$TEMP_MATCHES_FILE"
    fi
    if [[ -n "${TEMP_TERMS_FILE:-}" && -f "$TEMP_TERMS_FILE" ]]; then
        rm -f "$TEMP_TERMS_FILE"
    fi
    
    # Clean up temporary matches.json unless --keep-temp is specified
    if [[ "$ARG_KEEP_TEMP" != "true" && -f "tmp/matches.json" ]]; then
        rm -f "tmp/matches.json"
        # Remove tmp directory if empty
        if [[ -d "tmp" ]] && [[ -z "$(ls -A tmp)" ]]; then
            rmdir "tmp"
        fi
    fi
}

trap cleanup EXIT

#==============================================================================
# MAIN FUNCTION
#==============================================================================

main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Environment validation
    check_bash_version || exit 1
    check_dependencies || exit 1
    
    # Load and validate configuration
    load_config || exit 1
    validate_config || exit 1
    validate_wordpress || exit 1
    
    # Initialize caches
    cache_taxonomy_terms || exit 1
    
    # Choose processing method based on --preprocess flag
    if [[ "$ARG_PREPROCESS" == "true" ]]; then
        # Use Python preprocessor for fast matching
        run_python_preprocessor || exit 1
        load_matches_from_json || exit 1
    else
        # Use legacy Bash matching
        get_media_attachments || exit 1
        process_keyword_matches
    fi
    
    # Execute based on mode
    if [[ "$ARG_EXPORT" == "true" ]]; then
        export_mode
    elif [[ "$ARG_APPLY" == "true" ]]; then
        apply_mode
    else
        dry_run_mode
    fi
}

# Execute main function with all arguments
main "$@"
