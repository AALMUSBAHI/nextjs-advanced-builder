#!/bin/bash

# ===============================================================================
# Script: nextjs_ssr_build_pro (v4.0.0)
# Purpose: Automated Next.js SSR build with centralized configuration
# ===============================================================================

# ===============================================================================
# STEP CONFIGURATION (CUSTOMIZE HERE)
# ===============================================================================

# Instructions:
# 1. To change step order: Modify the STEP_ORDER array below
# 2. To configure steps: Edit the STEP_METADATA entries
#    - Format: [step_name]="Description|Detailed explanation|DefaultEnabled(0/1)|ShowOutput(0/1)"
#    - DefaultEnabled: 1=enabled by default, 0=disabled by default
#    - ShowOutput: 1=show command output, 0=hide output (default)
# 3. To add new steps:
#    a) Add to STEP_ORDER array
#    b) Add new entry in STEP_METADATA
#    c) Implement the step in the run_step() function

# Define the execution order of all steps
STEP_ORDER=(
    ssr_check
    cleanup
    security_audit
    dependencies
    check_updates
    optimize
    lint_checks
    type_checks
    build
    postbuild
    size_report
    bundle_analyze
    permissions
    docker_prep
)

# Step configuration (one entry per line for readability)
declare -A STEP_METADATA=(
    [ssr_check]="SSR Environment Check|Verify Node version, SSR env vars, and required configurations|0|0"
    [cleanup]="Cleanup Phase|Remove node_modules, .next, .cache, and other build artifacts|1|0"
    [security_audit]="Security Audit|Check for vulnerable dependencies before installation|1|0"
    [dependencies]="Dependency Management|Install dependencies, handle version conflicts|1|0"
    [check_updates]="Dependency Updates Check|Check for outdated dependencies and prompt to update|1|1"
    [optimize]="SSR Optimization|Configure SSR-specific optimizations and browser compatibility|1|0"
    [lint_checks]="Lint Checks|Run ESLint and code quality checks|1|0"
    [type_checks]="Type Checks|Run TypeScript compilation checks|1|0"
    [build]="Production Build|Execute production build with SSR configurations|1|0"
    [postbuild]="Post-Build Phase|Post-build cleanup, permissions, and optimizations|1|0"
    [size_report]="Build Size Report|Generate detailed report of build size changes|1|1"
    [bundle_analyze]="Bundle Analysis|Interactive bundle analysis with @next/bundle-analyzer|1|0"
    [permissions]="Fix Permissions|Set correct file permissions for deployment|0|0"
    [docker_prep]="Docker Preparation|Prepare Docker artifacts and optimize for containerization|0|0"
)

# ===============================================================================
# INITIALIZATION
# ===============================================================================

# Colors (using tput)
GREEN=$(tput setaf 2)
BRIGHT_GREEN=$(tput setaf 10)
RED=$(tput setaf 1)
BRIGHT_RED=$(tput setaf 9)
YELLOW=$(tput setaf 3)
BRIGHT_YELLOW=$(tput setaf 11)
BLUE=$(tput setaf 4)
CYAN=$(tput setaf 6)
PURPLE=$(tput setaf 5)
WHITE=$(tput setaf 7)
GRAY=$(tput setaf 8)
BOLD=$(tput bold)
RESET=$(tput sgr0)

# Background colors with white text
GREEN_BG="${BOLD}$(tput setab 2)${WHITE}"  # Green background, white text
RED_BG="${BOLD}$(tput setab 1)${WHITE}"    # Red background, white text
BOX_COLOR="${BOLD}${YELLOW}"

# Initialize variables
CI_MODE=0
FORCE_MODE=0
TARGET_DIR=""
STATS_SUCCESS=()
STATS_SKIPPED=()
STATS_WARNINGS=()
STATS_ERRORS=()
LOG_DIR="/tmp/nextjs_build_logs"
mkdir -p "$LOG_DIR"

# Parse metadata into separate arrays
declare -A STEP_DESCRIPTIONS
declare -A STEP_DETAILS
declare -A STEP_FLAGS
declare -A STEP_SHOW_OUTPUT

for step in "${!STEP_METADATA[@]}"; do
    IFS='|' read -r desc details enabled show_output <<< "${STEP_METADATA[$step]}"
    STEP_DESCRIPTIONS[$step]="$desc"
    STEP_DETAILS[$step]="$details"
    STEP_FLAGS[$step]="$enabled"
    STEP_SHOW_OUTPUT[$step]="$show_output"
done

# Trap to ensure colors are reset when script exits
trap 'echo -n "$RESET"' EXIT

# ===============================================================================
# UTILITY FUNCTIONS
# ===============================================================================

show_help() {
    cat <<EOF
${BOLD}${CYAN}Next.js SSR Build Pro - Usage${RESET}

${BOLD}Required:${RESET}
  ${GREEN}<project-path>${RESET}  Path to Next.js project directory

${BOLD}Options:${RESET}
  ${YELLOW}--ci${RESET}     Run in CI/CD mode (non-interactive)
  ${YELLOW}--force${RESET}  Skip all confirmation prompts
  ${YELLOW}--help${RESET}   Show this help
  ${YELLOW}--steps${RESET}  List available build steps

${BOLD}Examples:${RESET}
  ${GREEN}./$(basename "$0") ~/projects/my-app${RESET}    # Interactive mode
  ${GREEN}./$(basename "$0") --ci /var/www/app${RESET}   # CI mode
EOF
    exit 0
}

validate_path() {
    if [ -z "$TARGET_DIR" ]; then
        echo "${RED}ERROR: No project path specified${RESET}" >&2
        show_help
        exit 1
    fi

    if [ ! -d "$TARGET_DIR" ]; then
        echo "${RED}ERROR: Directory '$TARGET_DIR' not found${RESET}" >&2
        exit 1
    fi

    if [ ! -r "$TARGET_DIR" ] || [ ! -w "$TARGET_DIR" ]; then
        echo "${RED}ERROR: Can't access '$TARGET_DIR' (check permissions)${RESET}" >&2
        exit 1
    fi
}

is_nextjs_app() {
    local indicators=(
        "next.config.js"
        "next.config.ts"
        "pages/"
        "app/"
        "middleware"
        "next-env.d.ts"
    )
    
    local found=0
    for indicator in "${indicators[@]}"; do
        if [ -f "$indicator" ] || [ -d "$indicator" ]; then
            ((found++))
        fi
    done
    
    [ $found -ge 2 ] && return 0
    return 1
}

prompt_continue() {
    [ $CI_MODE -eq 1 ] || [ $FORCE_MODE -eq 1 ] && return 0
    read -p "$1 (y/n): " choice
    [[ "$choice" =~ ^[Yy]$ ]]
}

# ===============================================================================
# STATISTICS FUNCTIONS
# ===============================================================================

record_success() {
    STATS_SUCCESS+=("$1")
}

record_skipped() {
    STATS_SKIPPED+=("$1")
}

record_warning() {
    STATS_WARNINGS+=("$1")
}

record_error() {
    STATS_ERRORS+=("$1")
}

show_logs_menu() {
    clear
    echo -e "${CYAN}=== Execution Logs Viewer ===${RESET}"
    echo -e "Select a step to view its execution logs:\n"
    
    local i=1
    declare -A step_map
    for step in "${STEP_ORDER[@]}"; do
        step_map[$i]="$step"
        local status=""
        local color=""
        
        if printf '%s\n' "${STATS_SUCCESS[@]}" | grep -q "^${STEP_DESCRIPTIONS[$step]}$"; then
            status="success"
            color="${GREEN}"
        elif printf '%s\n' "${STATS_SKIPPED[@]}" | grep -q "^${STEP_DESCRIPTIONS[$step]}$"; then
            status="skipped"
            color="${GRAY}"
        elif printf '%s\n' "${STATS_WARNINGS[@]}" | grep -q "^${STEP_DESCRIPTIONS[$step]}$"; then
            status="warning"
            color="${YELLOW}"
        elif printf '%s\n' "${STATS_ERRORS[@]}" | grep -q "^${STEP_DESCRIPTIONS[$step]}$"; then
            status="failed"
            color="${RED}"
        else
            continue
        fi
        
        printf "%2d. %-40s ${color}%s${RESET}\n" "$i" "${STEP_DESCRIPTIONS[$step]}" "$status"
        ((i++))
    done
    
    echo -e "\n${GREEN}$i) Back to Statistics${RESET}"
    echo -e "${RED}0) Exit${RESET}"
    
    read -p "Select step to view logs: " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if [ "$choice" -eq 0 ]; then
            exit 0
        elif [ "$choice" -eq "$i" ]; then
            return
        elif [ -n "${step_map[$choice]}" ]; then
            local selected_step="${step_map[$choice]}"
            local log_file="$LOG_DIR/${selected_step}.log"
            
            if [ -f "$log_file" ]; then
                clear
                echo -e "${CYAN}=== Logs for: ${STEP_DESCRIPTIONS[$selected_step]} ===${RESET}"
                cat "$log_file"
                echo -e "\n${CYAN}=== End of Log ===${RESET}"
                read -p "Press Enter to continue..."
            else
                echo -e "${YELLOW}No logs available for this step${RESET}"
                sleep 1
            fi
        else
            echo -e "${RED}Invalid selection!${RESET}"
            sleep 1
        fi
    fi
    
    show_logs_menu
}

show_statistics() {
    while true; do
        clear
        echo -e "\n${CYAN}=== Build Statistics ===${RESET}"
        
        # Calculate maximum length for alignment
        local max_len=0
        for step in "${STEP_ORDER[@]}"; do
            [ ${#STEP_DESCRIPTIONS[$step]} -gt $max_len ] && max_len=${#STEP_DESCRIPTIONS[$step]}
        done
        ((max_len+=2))

        # Print table header
        printf "%-${max_len}s %s\n" "${BOLD}Step${RESET}" "${BOLD}Status${RESET}"
        printf "%-${max_len}s %s\n" "---------------------" "---------------------"

        # Print each item in order with its status
        for step in "${STEP_ORDER[@]}"; do
            local title="${STEP_DESCRIPTIONS[$step]}"
            local status=""
            local color=""
            
            if printf '%s\n' "${STATS_SUCCESS[@]}" | grep -q "^${title}$"; then
                status="success"
                color="${GREEN}"
            elif printf '%s\n' "${STATS_SKIPPED[@]}" | grep -q "^${title}$"; then
                status="skipped"
                color="${GRAY}"
            elif printf '%s\n' "${STATS_WARNINGS[@]}" | grep -q "^${title}$"; then
                status="warning"
                color="${YELLOW}"
            elif printf '%s\n' "${STATS_ERRORS[@]}" | grep -q "^${title}$"; then
                status="failed"
                color="${RED}"
            else
                continue
            fi

            printf "%-${max_len}s ${color}%s${RESET}\n" "$title" "$status"
        done

        # Print summary
        echo -e "\n${BOLD}Summary:${RESET}"
        echo "  Successful: ${#STATS_SUCCESS[@]}"
        echo "  Warnings:   ${#STATS_WARNINGS[@]}"
        echo "  Skipped:    ${#STATS_SKIPPED[@]}"
        echo "  Errors:     ${#STATS_ERRORS[@]}"
        echo "  Total:      ${#STEP_ORDER[@]} steps"
        
        echo -e "\n${CYAN}Options:${RESET}"
        echo "1. View step detailed logs"
        echo "2. Return to main menu"
        echo "0. Exit"
        
        read -p "Select option: " choice
        
        case $choice in
            1) show_logs_menu ;;
            2) break ;;
            0) exit 0 ;;
            *) echo -e "${RED}Invalid option!${RESET}"; sleep 1 ;;
        esac
    done
}

# ===============================================================================
# STEP MANAGEMENT
# ===============================================================================

count_enabled_steps() {
    local count=0
    for step in "${STEP_ORDER[@]}"; do
        [ "${STEP_FLAGS[$step]}" -eq 1 ] && ((count++))
    done
    echo "$count"
}

draw_box() {
    # Initialize variables
    local items=()
    local colors=()
    local i=0

    # Process all arguments
    while [ $# -gt 0 ]; do
        colors[i]="$1"
        items[i]="$2"
        ((i++))
        shift 2
    done

    # Function to calculate visible width
    visible_width() {
        # Strip color codes
        local stripped=$(echo -e "$1" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
        # Use bash's built-in string length for ASCII characters
        local ascii_length=${#stripped}
        # Count double-width characters
        local wide_chars=$(echo -n "$stripped" | grep -oP '[^\x00-\x7F]' | wc -l)
        echo $((ascii_length + wide_chars))
    }

    # Calculate total visible width
    local total_width=0
    for (( idx=0; idx<${#items[@]}; idx++ )); do
        total_width=$((total_width + $(visible_width "${items[idx]}")))
        if [ $idx -lt $((${#items[@]} - 1)) ]; then
            total_width=$((total_width + 3)) # " │ " is 3 characters wide
        fi
    done

    # Add 2 for padding (1 space on each side)
    total_width=$((total_width + 2))

    # Build the content line with colors
    local content_line=""
    for (( idx=0; idx<${#items[@]}; idx++ )); do
        content_line+="${colors[idx]}${items[idx]}${RESET}"
        if [ $idx -lt $((${#items[@]} - 1)) ]; then
            content_line+=" ${BOX_COLOR}│${RESET} "
        fi
    done

    # Draw the box
    echo -en "${BOX_COLOR}╭"
    printf '─%.0s' $(seq 1 $total_width)
    echo -e "╮${RESET}"

    echo -e "${BOX_COLOR}│${RESET} ${content_line} ${BOX_COLOR}│${RESET}"

    echo -en "${BOX_COLOR}╰"
    printf '─%.0s' $(seq 1 $total_width)
    echo -e "╯${RESET}"
}

print_step_menu() {
    clear
    echo -e "${CYAN}=== Build Step Configuration ===${RESET}"
	
    # Legend
    echo -e "\n${YELLOW}Legend:${RESET} ${GRAY}□${RESET}=Disabled ${GREEN}■${RESET}=Enabled(hidden) ${BLUE}●${RESET}=Enabled(shown)"
	echo -e "${YELLOW}Press step number repeatedly to cycle through states${RESET}\n"
	
    # Calculate column widths
    local step_num_width=${#STEP_ORDER[@]}
    step_num_width=${#step_num_width} # Get digit count
    
    # Find longest step name for alignment
    local max_name_len=0
    for step in "${STEP_ORDER[@]}"; do
        [ ${#STEP_DESCRIPTIONS[$step]} -gt $max_name_len ] && max_name_len=${#STEP_DESCRIPTIONS[$step]}
    done
    
    local i=1
    for step in "${STEP_ORDER[@]}"; do
        # Determine state indicator
        local state_indicator
        if [ ${STEP_FLAGS[$step]} -eq 0 ]; then
            state_indicator="${GRAY}□${RESET}" # Disabled
        elif [ ${STEP_SHOW_OUTPUT[$step]} -eq 0 ]; then
            state_indicator="${GREEN}■${RESET}" # Enabled, output hidden
        else
            state_indicator="${BLUE}●${RESET}" # Enabled, output shown
        fi
        
        printf "%s %${step_num_width}d. %-${max_name_len}s ${GRAY}(%s)${RESET}\n" \
               "$state_indicator" \
               "$i" \
               "${STEP_DESCRIPTIONS[$step]}" \
               "${STEP_DETAILS[$step]}"
        ((i++))
    done
    
    # Bulk actions box
    # draw_box \
    #    "${GRAY}" "d) Disable ALL steps" \
    #    "${GREEN}" "e) Enable ALL (output hidden)" \
    #    "${BLUE}" "o) Enable ALL (output shown)"
    
    # Start and Exit options
    #echo -e "\n${GREEN_BG}s) Start Build${RESET}"
    #echo -e "${RED_BG}0) Exit${RESET}"
}

choose_steps() {
    while true; do
        print_step_menu
        
        # Tight input validation loop
        while true; do
            draw_box \
            "${RESET}" "Select (1-${#STEP_ORDER[@]}) " \
            "${GRAY}" "D)isable All " \
            "${BRIGHT_GREEN}" "E)nable All (Silent)" \
            "${BLUE}" "O)utput Enabled for All" \
            "${BRIGHT_YELLOW}" "S)tart Build"\
			"${RED}" "0) Exit"\
        
			# Display input prompt
			echo -en "${BOLD}${WHITE}❯ ${RESET}"
            read -p "" choice
            
            case "$choice" in
                [0-9]*)
                    (( choice >= 0 && choice <= ${#STEP_ORDER[@]} )) && break
                    ;;
                [dDeEoOsS])
                    break ;;
                *)
                    echo -e "${RED}Invalid input!${RESET}" >&2
                    continue ;;
            esac
        done

        # Rest of the function remains the same...
        case "${choice^^}" in
            0) exit 0 ;;
            S) break ;;
            D)
                for step in "${STEP_ORDER[@]}"; do
                    STEP_FLAGS[$step]=0
                    STEP_SHOW_OUTPUT[$step]=0
                done
                ;;
            E)
                for step in "${STEP_ORDER[@]}"; do
                    STEP_FLAGS[$step]=1
                    STEP_SHOW_OUTPUT[$step]=0
                done
                ;;
            O)
                for step in "${STEP_ORDER[@]}"; do
                    STEP_FLAGS[$step]=1
                    STEP_SHOW_OUTPUT[$step]=1
                done
                ;;
            *)
                local i=1
                for step in "${STEP_ORDER[@]}"; do
                    if [[ "$choice" -eq "$i" ]]; then
                        case "${STEP_FLAGS[$step]}:${STEP_SHOW_OUTPUT[$step]}" in
                            0:0) STEP_FLAGS[$step]=1 ;;
                            1:0) STEP_SHOW_OUTPUT[$step]=1 ;;
                            *)   STEP_FLAGS[$step]=0 ;;
                        esac
                        break
                    fi
                    ((i++))
                done
                ;;
        esac
    done
}

# Helper function for step state toggling
toggle_step_state() {
    local step="$1"
    case "${STEP_FLAGS[$step]}:${STEP_SHOW_OUTPUT[$step]}" in
        0:0)  # Disabled → Enable (hidden)
            STEP_FLAGS[$step]=1
            STEP_SHOW_OUTPUT[$step]=0
            echo -e "${GREEN}Enabled ${STEP_DESCRIPTIONS[$step]} (output hidden)${RESET}"
            ;;
        1:0)  # Enabled (hidden) → Enabled (shown)
            STEP_SHOW_OUTPUT[$step]=1
            echo -e "${BLUE}Enabled ${STEP_DESCRIPTIONS[$step]} (output shown)${RESET}"
            ;;
        *)    # Enabled (shown) or other → Disabled
            STEP_FLAGS[$step]=0
            STEP_SHOW_OUTPUT[$step]=0
            echo -e "${YELLOW}Disabled ${STEP_DESCRIPTIONS[$step]}${RESET}"
            ;;
    esac
    sleep 0.5
}

# Helper function for confirmation prompts
confirm_action() {
    local message="$1"
    while true; do
        read -p "${YELLOW}${message} [y/N] ${RESET}" confirm
        case "${confirm^^}" in
            Y|YES) return 0 ;;
            N|NO|"") return 1 ;;
            *) echo -e "${RED}Please answer yes or no.${RESET}" ;;
        esac
    done
}

# ===============================================================================
# STEP IMPLEMENTATIONS
# ===============================================================================

run_step() {
    local step="$1"
    local title="${STEP_DESCRIPTIONS[$step]}"
    local detail="${STEP_DETAILS[$step]}"
    local success=false
    local skip=false
    local warning=false
    local log_file="$LOG_DIR/${step}.log"

    if [ ${STEP_FLAGS[$step]} -eq 1 ]; then
        echo -e "\n${CYAN}=== Running: ${title} ===${RESET}"
        echo -e "${BLUE}Purpose: ${detail}${RESET}"

        # Unified command execution function
        execute_command() {
            local cmd="$1"
            local tmp_output=$(mktemp)
            
            # Start time for performance measurement
            local start_time=$(date +%s.%N)
            
            # Log command being executed
            echo "Executing: $cmd" > "$log_file"
            echo "Timestamp: $(date)" >> "$log_file"
            
			 # Respect ShowOutput setting even in --force mode
            if [ ${STEP_SHOW_OUTPUT[$step]} -eq 1 ]; then
                # Execute command while preserving original output and colors
                eval "$cmd" 2>&1 | tee -a "$log_file" "$tmp_output"
                local exit_code=${PIPESTATUS[0]}
            else
                echo "Running command (output hidden)..." | tee -a "$log_file"
                eval "$cmd" >> "$log_file" 2>&1
                local exit_code=$?
                echo "Command completed" | tee -a "$log_file"
            fi
            
            # End time and duration calculation
            local end_time=$(date +%s.%N)
            local duration=$(echo "$end_time - $start_time" | bc)
            echo "Duration: $duration seconds" >> "$log_file"
            
            # Check for warnings in output (case insensitive)
            if grep -qi "warning" "$log_file"; then
                warning=true
            fi
            
            rm -f "$tmp_output"
            return $exit_code
        }

        case "$step" in
            ssr_check)
                SSR_MIN_NODE=16
                CURRENT_NODE=$(node -v | cut -d"v" -f2 | cut -d"." -f1)
                if [ "$CURRENT_NODE" -lt "$SSR_MIN_NODE" ]; then
                    echo -e "${RED}✗ SSR requires Node.js v${SSR_MIN_NODE}+ (current: v${CURRENT_NODE})${RESET}" >&2
                    [ $CI_MODE -eq 1 ] && exit 1
                    prompt_continue "Continue with unsupported Node.js version?" || skip=true
                fi
                
                declare -A SSR_ENV_VARS=(
                    ["NEXT_PUBLIC_SSR_MODE"]="enabled"
                    ["SESSION_SECRET"]=""
                )
                
                for var in "${!SSR_ENV_VARS[@]}"; do
                    if [ -z "${!var:-}" ]; then
                        echo -e "${YELLOW}⚠ Missing SSR variable: $var${RESET}" >&2
                        warning=true
                    fi
                done
                [ "$skip" != "true" ] && success=true
                ;;

            cleanup)
                prompt_continue "Proceed with cleanup?" || { skip=true; break; }
                for dir in node_modules .next .cache; do
                    if [ -d "$dir" ]; then
                        echo -e "${BLUE}Cleaning $dir...${RESET}"
                        rm -rf "$dir" || { success=false; break; }
                    fi
                done
                success=true
                ;;

            security_audit)
                prompt_continue "Run security audit?" || { skip=true; break; }
                if ! execute_command "npm audit"; then
                    prompt_continue "Security audit found vulnerabilities. Attempt to fix?" && {
                        execute_command "npm audit fix --force" && success=true || success=false
                    }
                else
                    success=true
                fi
                ;;

            dependencies)
                prompt_continue "Install dependencies?" || { skip=true; break; }
                execute_command "npm install" && success=true || success=false
                ;;

            check_updates)
                if [ $FORCE_MODE -eq 1 ]; then
                    # In force mode, just show outdated packages without updating
                    execute_command "npm outdated" || true
                    echo -e "${YELLOW}↪ Skipping automatic updates in --force mode${RESET}"
                    success=true
                else
                    # Normal interactive behavior
                    prompt_continue "Check for dependency updates?" || { skip=true; break; }
                    execute_command "npm outdated" || true
                    if command -v ncu &>/dev/null; then
                        execute_command "ncu --color"
                        if ! execute_command "ncu --color" | grep -q "All dependencies match"; then
                            prompt_continue "Install these updates using ncu?" && {
                                execute_command "ncu -u && npm install" && success=true || success=false
                            }
                        else
                            success=true
                        fi
                    else
                        prompt_continue "Install npm-check-updates?" && {
                            execute_command "npm install -g npm-check-updates" && warning=true || success=false
                        }
                    fi
                fi
                ;;

            optimize)
                prompt_continue "Configure optimizations?" || { skip=true; break; }
                if [ -f "next.config.js" ]; then
                    if ! grep -q "serverComponentsExternalPackages" next.config.js; then
                        sed -i '/module.exports =/a\  experimental: { serverComponentsExternalPackages: ["@prisma/client", "lodash-es"] },' next.config.js || success=false
                    fi
                fi
                execute_command "npx update-browserslist-db@latest --yes" && success=true || success=false
                ;;

            lint_checks)
                prompt_continue "Run lint checks?" || { skip=true; break; }
                execute_command "npm run lint" && success=true || success=false
                ;;

            type_checks)
                prompt_continue "Run type checks?" || { skip=true; break; }
                execute_command "npm run typecheck" && success=true || success=false
                [ $CI_MODE -eq 1 ] && [ "$success" = false ] && exit 1
                ;;

            build)
                prompt_continue "Start production build?" || { skip=true; break; }
                execute_command "NODE_ENV=production npm run build" && success=true || success=false
                ;;

            postbuild)
                prompt_continue "Run post-build tasks?" || { skip=true; break; }
                execute_command "npm prune --omit=dev" && success=true || success=false
                ;;

            size_report)
                prompt_continue "Generate size report?" || { skip=true; break; }
                execute_command 'du -sh .next; du -sh .next/static/*' && success=true || success=false
                ;;

            bundle_analyze)
                prompt_continue "Run bundle analysis?" || { skip=true; break; }
                execute_command "npm install --no-save @next/bundle-analyzer && ANALYZE=1 npm run build" && success=true || success=false
                ;;

            permissions)
                prompt_continue "Fix permissions?" || { skip=true; break; }
                if command -v fixnodePermissions.sh >/dev/null; then
                    execute_command "fixnodePermissions.sh \"$(pwd)\"" && success=true || success=false
                else
                    warning=true
                fi
                ;;

            docker_prep)
                prompt_continue "Prepare Docker artifacts?" || { skip=true; break; }
                if [ -f "Dockerfile" ]; then
                    execute_command "docker build -t nextjs-ssr ." && success=true || success=false
                else
                    warning=true
                fi
                ;;

            *)
                echo -e "${RED}Unknown step: $step${RESET}" >&2
                success=false
                ;;
        esac

        # Record final status
        if [ "$skip" = "true" ]; then
            echo -e "${YELLOW}↪ Skipped: ${title}${RESET}"
            record_skipped "$title"
        elif $success; then
            if [ "$warning" = "true" ]; then
                echo -e "${YELLOW}⚠ ${title} completed with warnings${RESET}"
                record_warning "$title"
            else
                echo -e "${GREEN}✓ ${title} completed successfully${RESET}"
                record_success "$title"
            fi
        else
            echo -e "${RED}✗ ${title} encountered errors${RESET}" >&2
            record_error "$title"
            [ $CI_MODE -eq 1 ] && exit 1
        fi
    else
        echo -e "${GRAY}↪ Skipping: ${title} (disabled)${RESET}"
        record_skipped "$title"
    fi
}

# ===============================================================================
# MAIN EXECUTION
# ===============================================================================

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --ci) CI_MODE=1 ;;
        --force) FORCE_MODE=1 ;;
        --help) show_help ;;
        *) 
            if [ -z "$TARGET_DIR" ]; then
                TARGET_DIR="$arg"
            else
                echo "${RED}ERROR: Multiple paths specified${RESET}" >&2
                show_help
                exit 1
            fi
            ;;
    esac
done

# Validate path before proceeding
validate_path

# Change to target directory
cd "$TARGET_DIR" || {
    echo -e "${RED}✗ Failed to enter '$TARGET_DIR'!${RESET}" >&2
    exit 1
}

echo -e "${GREEN}✓ Working directory: $TARGET_DIR${RESET}"

# Verify Next.js project
if ! is_nextjs_app; then
    echo -e "${RED}✗ This doesn't appear to be a Next.js project.${RESET}"
    [ $CI_MODE -eq 0 ] && [ $FORCE_MODE -eq 0 ] && \
        prompt_continue "Continue anyway?" || exit 1
fi

# Interactive step selection
[ $CI_MODE -eq 0 ] && [ $FORCE_MODE -eq 0 ] && choose_steps

echo -e "\n${CYAN}=== Starting Build Process ===${RESET}"
echo -e "${BLUE}Running with ${PURPLE}$(count_enabled_steps)${BLUE} of ${#STEP_ORDER[@]} steps${RESET}"

# Execute all enabled steps in configured order
for step in "${STEP_ORDER[@]}"; do
    run_step "$step"
done

# Show final statistics
if [ ${#STATS_ERRORS[@]} -eq 0 ]; then
    echo -e "\n${GREEN}✔ Build Completed Successfully!${RESET}"
else
    echo -e "\n${YELLOW}⚠ Build Completed with ${#STATS_ERRORS[@]} warnings/errors${RESET}"
fi

show_statistics

echo -e "\n${CYAN}Next Steps:${RESET}"
echo -e "1. Start application: npm start"
echo -e "2. Monitor logs: tail -f logs/application.log"
echo -e "3. Deployment checklist:"
echo -e "   - Verify environment variables"
echo -e "   - Check health endpoints"
echo -e "   - Monitor resource usage"

exit 0
