#!/bin/bash

# Infinite Claude Code - Combined start and babysit functionality
# Starts Claude Code sessions with built-in monitoring and auto-continuation

# Default values (can be overridden via environment)
SESSION_NAME="${CLAUDE_SESSION_NAME:-claude-code}"
WAIT_TIME=1  # minutes
WORK_DIR=""  # Will be set to launch directory if not specified
FORCE_RESTART=false
MAX_RETRIES=3
RETRY_DELAY=5
AUTO_SUBMIT=true
AUTO_SUBMIT_TIMEOUT=1  # minutes before auto-submitting
MONITOR_MODE=false
CHECK_INTERVAL="${CLAUDE_CHECK_INTERVAL:-5}"  # seconds between checks
CONTINUE_PROMPT="Continue"
DEBUG_MODE=false
DEBUG_FILE="/tmp/infinite-claude-debug.log"
MODEL=""  # Claude model to use (e.g., haiku, sonnet, opus)

# Capture the current working directory where script is launched
LAUNCH_DIR="$(pwd)"

# Babysit defaults (built-in)
BABYSIT_CHECK_INTERVAL=300  # Check every 5 minutes
BABYSIT_STUCK_THRESHOLD=900  # Consider stuck if idle for 15 minutes
BABYSIT_MAX_RUNTIME=28800   # Run for 8 hours (8 * 60 * 60)
LOG_FILE="/tmp/claude-babysit.log"

# Content hash tracking for activity detection
LAST_CONTENT_HASH=""
LAST_CONTENT_CHANGE_TIME=$(date +%s)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --pwd)
            WORK_DIR="$2"
            shift 2
            ;;
        --wait-time)
            WAIT_TIME="$2"
            shift 2
            ;;
        --auto-submit-timeout)
            AUTO_SUBMIT_TIMEOUT="$2"
            shift 2
            ;;
        --no-auto-submit)
            AUTO_SUBMIT=false
            shift
            ;;
        --continue-prompt)
            CONTINUE_PROMPT="$2"
            shift 2
            ;;
        --monitor)
            MONITOR_MODE=true
            shift
            ;;
        --debug)
            DEBUG_MODE=true
            if [[ -n "$2" && "$2" != --* ]]; then
                DEBUG_FILE="$2"
                shift
            fi
            shift
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --force|-f)
            FORCE_RESTART=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] \"INITIAL_PROMPT\" [--continue-prompt \"CONTINUE_PROMPT\"]"
            echo ""
            echo "Options:"
            echo "  --pwd DIRECTORY              Change to this directory before running Claude Code"
            echo "  --wait-time MINUTES          Wait time in minutes to consider session idle (default: 1)"
            echo "  --auto-submit-timeout MIN    Minutes of inactivity before auto-submitting (default: 1, supports fractions like 0.5)"
            echo "  --no-auto-submit             Disable auto-submit feature"
            echo "  --continue-prompt PROMPT     Prompt to send when session becomes idle (default: Continue)"
            echo "  --monitor                    Run in monitor mode only (no prompt needed)"
            echo "  --debug [FILE]               Enable debug mode, write to FILE (default: /tmp/infinite-claude-debug.log)"
            echo "  --model MODEL                Claude model to use (e.g., haiku, sonnet, opus)"
            echo "  --force, -f                  Force restart the session even if it exists"
            echo "  --help, -h                   Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 \"Refactor to TypeScript\""
            echo "  $0 \"Refactor to TypeScript\" --continue-prompt \"Keep working\""
            echo "  $0 --pwd ~/project \"Add error handling\""
            echo "  $0 --monitor              # Just monitor existing session"
            echo "  $0 --debug \"Start task\"  # Enable debug logging to /tmp/infinite-claude-debug.log"
            echo "  $0 --debug /tmp/my.log \"Start task\"  # Custom debug log file"
            exit 0
            ;;
        *)
            if [ -z "$INITIAL_PROMPT" ]; then
                INITIAL_PROMPT="$1"
            else
                echo "ERROR: Multiple prompts provided. Use --continue-prompt for additional prompts."
                exit 1
            fi
            shift
            ;;
    esac
done

# Set default working directory to launch directory if not specified
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$LAUNCH_DIR"
fi

# Function to log messages with timestamp (handles buffer overflow gracefully)
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    # Retry up to 3 times with small delay if write fails
    local retries=0
    while ! echo "$msg" 2>/dev/null && [ $retries -lt 3 ]; do
        sleep 0.1
        retries=$((retries + 1))
    done
}

# Function to write debug messages to file
debug_log() {
    if [ "$DEBUG_MODE" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$DEBUG_FILE"
    fi
}

# Function to compute MD5 hash of content (for change detection)
content_hash() {
    echo "$1" | md5 -q 2>/dev/null || echo "$1" | md5sum 2>/dev/null | cut -d' ' -f1
}

# Initialize debug file if debug mode is enabled
init_debug() {
    if [ "$DEBUG_MODE" = true ]; then
        echo "=== Infinite Claude Code Debug Log ===" > "$DEBUG_FILE"
        echo "Started: $(date)" >> "$DEBUG_FILE"
        echo "DEBUG_FILE: $DEBUG_FILE" >> "$DEBUG_FILE"
        echo "SESSION_NAME: $SESSION_NAME" >> "$DEBUG_FILE"
        echo "AUTO_SUBMIT_TIMEOUT: $AUTO_SUBMIT_TIMEOUT minutes" >> "$DEBUG_FILE"
        echo "CHECK_INTERVAL: $CHECK_INTERVAL seconds" >> "$DEBUG_FILE"
        echo "BABYSIT_STUCK_THRESHOLD: $BABYSIT_STUCK_THRESHOLD seconds" >> "$DEBUG_FILE"
        echo "========================================" >> "$DEBUG_FILE"
        log "Debug mode enabled, writing to: $DEBUG_FILE"
    fi
}

# Function to check dependencies
check_dependencies() {
    local missing=()

    if ! command -v tmux &> /dev/null; then
        missing+=("tmux")
    fi

    if ! command -v claude &> /dev/null; then
        missing+=("claude")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log "ERROR: Missing dependencies: ${missing[*]}"
        log "Please install missing dependencies and try again."
        exit 1
    fi
}

# Validate inputs
validate_input() {
    # In monitor mode, we don't need a prompt
    if [ "$MONITOR_MODE" = true ]; then
        return 0
    fi

    if [ -z "$INITIAL_PROMPT" ]; then
        log "ERROR: No initial prompt provided"
        echo "Usage: $0 [--pwd DIRECTORY] [--wait-time MINUTES] [--force] \"INITIAL_PROMPT\" [--continue-prompt \"CONTINUE_PROMPT\"]"
        exit 1
    fi

    # Validate wait_time is a positive number
    if ! [[ "$WAIT_TIME" =~ ^[0-9]+$ ]] || [ "$WAIT_TIME" -lt 1 ]; then
        log "ERROR: wait-time must be a positive number"
        exit 1
    fi

    # Validate directory if provided
    if [ -n "$WORK_DIR" ] && [ ! -d "$WORK_DIR" ]; then
        log "ERROR: Directory '$WORK_DIR' does not exist"
        exit 1
    fi
}

# Function to check if Claude process is running in the session
is_claude_running() {
    local session="$1"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "false"
        return
    fi

    # Check if there's a claude process running in the session
    local pane_pid=$(tmux display-message -p -t "$session" -F "#{pane_pid}")
    if pgrep -P "$pane_pid" -f "claude" > /dev/null 2>&1; then
        echo "true"
    else
        echo "false"
    fi
}

# Function to check if tmux session is idle based on CONTENT changes
# Note: #{window_activity} tracks window focus, NOT content changes!
# We use content hashing for accurate activity detection.
is_session_idle() {
    local session="$1"
    local wait_minutes="$2"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        debug_log "is_session_idle: session '$session' does not exist"
        echo "false"
        return
    fi

    # Check if Claude Code shows tasks in progress - not idle if working on tasks
    if [ "$(has_tasks_in_progress "$session")" = "true" ]; then
        debug_log "is_session_idle: tasks in progress, not idle"
        echo "false"
        return
    fi

    # Capture current pane content
    local current_content=$(tmux capture-pane -p -t "$session" -S -100 2>/dev/null)
    local current_hash=$(content_hash "$current_content")
    local current_time=$(date +%s)

    debug_log "is_session_idle: current_hash=$current_hash, LAST_CONTENT_HASH=$LAST_CONTENT_HASH"

    # Check if content has changed
    if [ "$current_hash" != "$LAST_CONTENT_HASH" ]; then
        # Content changed, update tracking
        LAST_CONTENT_HASH="$current_hash"
        LAST_CONTENT_CHANGE_TIME=$current_time
        debug_log "is_session_idle: content CHANGED, reset timer"
        echo "false"
        return
    fi

    # Content hasn't changed, check how long
    local idle_seconds=$((current_time - LAST_CONTENT_CHANGE_TIME))
    local idle_minutes=$((idle_seconds / 60))

    debug_log "is_session_idle: content stable for ${idle_seconds}s (${idle_minutes}min), threshold=${wait_minutes}min"

    if [ "$idle_minutes" -ge "$wait_minutes" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Function to check if Claude has active todos
has_active_todos() {
    local session="$1"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "false"
        return
    fi

    # Capture only the bottom portion of the pane (last 20 lines)
    # where the task list typically appears in Claude Code
    local pane_content=$(tmux capture-pane -p -t "$session" -S -20 2>/dev/null)

    # Check for task indicators - look for lines with task symbols
    # Active tasks show as ◼ (in progress) or ◻ (pending)
    local active_count=$(echo "$pane_content" | grep -cE '[◼◻].*[a-zA-Z]' 2>/dev/null || echo "0")

    if [ "$active_count" -gt 0 ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Function to check if Claude Code shows tasks in progress
# Detects output like: "17 tasks (10 done, 6 in progress, 1 open) · ctrl+t to hide task"
has_tasks_in_progress() {
    local session="$1"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "false"
        return
    fi

    # Capture the bottom portion of the pane where the status line appears
    local pane_content=$(tmux capture-pane -p -t "$session" -S -30 2>/dev/null)

    # Check for task progress indicator with "in progress" count > 0
    # Pattern: "N tasks (... X in progress ...)" where X > 0
    if echo "$pane_content" | grep -qE '[0-9]+ tasks \([^)]*[1-9][0-9]* in progress' 2>/dev/null; then
        debug_log "has_tasks_in_progress: found tasks in progress"
        echo "true"
    else
        echo "false"
    fi
}

# Babysit functions (merged from babysit.sh)

# Function to check if Claude is stuck (content-based detection)
is_claude_stuck() {
    local session="$1"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        debug_log "is_claude_stuck: session '$session' does not exist"
        echo "false"
        return
    fi

    # Check if Claude Code shows tasks in progress - not stuck if working on tasks
    if [ "$(has_tasks_in_progress "$session")" = "true" ]; then
        debug_log "is_claude_stuck: tasks in progress, not stuck"
        echo "false"
        return
    fi

    # Capture current pane content
    local current_content=$(tmux capture-pane -p -t "$session" -S -100 2>/dev/null)
    local current_hash=$(content_hash "$current_content")
    local current_time=$(date +%s)

    debug_log "is_claude_stuck: current_hash=$current_hash, LAST_CONTENT_HASH=$LAST_CONTENT_HASH"

    # Check if content has changed
    if [ "$current_hash" != "$LAST_CONTENT_HASH" ]; then
        # Content changed, update tracking
        LAST_CONTENT_HASH="$current_hash"
        LAST_CONTENT_CHANGE_TIME=$current_time
        debug_log "is_claude_stuck: content CHANGED, not stuck"
        echo "false"
        return
    fi

    # Content hasn't changed, check duration
    local idle_seconds=$((current_time - LAST_CONTENT_CHANGE_TIME))

    debug_log "is_claude_stuck: idle for ${idle_seconds}s, threshold=${BABYSIT_STUCK_THRESHOLD}s"

    if [ "$idle_seconds" -ge "$BABYSIT_STUCK_THRESHOLD" ]; then
        debug_log "is_claude_stuck: YES, stuck!"
        echo "true"
    else
        echo "false"
    fi
}

# Function to get idle time in minutes (content-based)
get_idle_minutes() {
    local session="$1"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "0"
        return
    fi

    # Check if Claude Code shows tasks in progress - not idle if working on tasks
    if [ "$(has_tasks_in_progress "$session")" = "true" ]; then
        debug_log "get_idle_minutes: tasks in progress, idle=0"
        echo "0"
        return
    fi

    # Capture current pane content
    local current_content=$(tmux capture-pane -p -t "$session" -S -100 2>/dev/null)
    local current_hash=$(content_hash "$current_content")
    local current_time=$(date +%s)

    # Check if content has changed
    if [ "$current_hash" != "$LAST_CONTENT_HASH" ]; then
        # Content changed, update tracking
        LAST_CONTENT_HASH="$current_hash"
        LAST_CONTENT_CHANGE_TIME=$current_time
        debug_log "get_idle_minutes: content changed, idle=0"
        echo "0"
        return
    fi

    local idle_seconds=$((current_time - LAST_CONTENT_CHANGE_TIME))
    local idle_minutes=$((idle_seconds / 60))
    debug_log "get_idle_minutes: ${idle_minutes}min (${idle_seconds}s)"
    echo "$idle_minutes"
}

# Function to count active todos
count_active_todos() {
    local session="$1"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "0"
        return
    fi

    # Capture bottom of screen
    local pane_content=$(tmux capture-pane -p -t "$session" -S -20 2>/dev/null)
    echo "$pane_content" | grep -cE '[◼◻].*[a-zA-Z]' 2>/dev/null || echo "0"
}

# Function to send a nudge prompt
send_nudge() {
    local session="$1"
    local reason="$2"

    log "BABYSIT NUDGE: $reason"
    log "Sending wake-up prompt..."

    if [ "$DEBUG_MODE" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] send_nudge: reason='$reason'" >> "$DEBUG_FILE"
    fi

    # Send Ctrl+C to cancel any current operation
    tmux send-keys -t "$session" "C-c" 2>/dev/null
    sleep 1

    # Send appropriate prompt based on state
    local active_todos=$(count_active_todos "$session")
    local prompt_text=""
    if [ "$active_todos" -gt 0 ]; then
        prompt_text="Continue working on your todo items. If stuck, try a different approach."
    else
        prompt_text="Continue working. Pick up the next task from the project directions."
    fi

    if [ "$DEBUG_MODE" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] send_nudge: sending prompt='$prompt_text'" >> "$DEBUG_FILE"
    fi

    tmux send-keys -t "$session" "$prompt_text" 2>/dev/null
    sleep 1
    tmux send-keys -t "$session" "Enter" 2>/dev/null

    log "Nudge sent!"
    if [ "$DEBUG_MODE" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] send_nudge: done" >> "$DEBUG_FILE"
    fi
}

# Function to check if there's an error/failure
has_error_state() {
    local session="$1"
    local pane_content=$(tmux capture-pane -p -t "$session" -S -30 2>/dev/null)

    # Look for error patterns
    if echo "$pane_content" | grep -qiE "error.*timeout|failed.*retry|compilation error|build failed"; then
        echo "true"
    else
        echo "false"
    fi
}

# Function to run babysit monitoring in background
start_babysit_monitor() {
    local session="$1"

    log "Starting babysit monitor (checks every ${BABYSIT_CHECK_INTERVAL}s, stuck threshold: ${BABYSIT_STUCK_THRESHOLD}s)"
    debug_log "start_babysit_monitor: session=$session, check_interval=${BABYSIT_CHECK_INTERVAL}s, stuck_threshold=${BABYSIT_STUCK_THRESHOLD}s"

    (
        # Initialize content tracking for this subprocess
        local babysit_last_hash=""
        local babysit_last_change_time=$(date +%s)
        local start_time=$(date +%s)
        local check_count=0

        while true; do
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))

            # Check if we've reached the time limit
            if [ $elapsed -ge $BABYSIT_MAX_RUNTIME ]; then
                log "Babysit monitor: 8 hours elapsed, shutting down"
                debug_log "babysit_monitor: max runtime reached, exiting"
                break
            fi

            check_count=$((check_count + 1))

            # Check if session still exists
            if ! tmux has-session -t "$session" 2>/dev/null; then
                log "Babysit monitor: Session '$session' not found, stopping"
                debug_log "babysit_monitor[$check_count]: session gone, exiting"
                break
            fi

            # Content-based activity detection
            local current_content=$(tmux capture-pane -p -t "$session" -S -100 2>/dev/null)
            local current_hash=$(echo "$current_content" | md5 -q 2>/dev/null || echo "$current_content" | md5sum 2>/dev/null | cut -d' ' -f1)

            if [ "$DEBUG_MODE" = true ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] babysit_monitor[$check_count]: hash=$current_hash, last=$babysit_last_hash" >> "$DEBUG_FILE"
            fi

            # Check if content changed
            if [ "$current_hash" != "$babysit_last_hash" ]; then
                babysit_last_hash="$current_hash"
                babysit_last_change_time=$current_time
                if [ "$DEBUG_MODE" = true ]; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] babysit_monitor[$check_count]: content CHANGED, reset timer" >> "$DEBUG_FILE"
                fi
            fi

            local idle_seconds=$((current_time - babysit_last_change_time))
            local idle_minutes=$((idle_seconds / 60))
            local active_todos=$(count_active_todos "$session")
            local has_error=$(has_error_state "$session")
            local tasks_running=$(has_tasks_in_progress "$session")

            if [ "$DEBUG_MODE" = true ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] babysit_monitor[$check_count]: idle=${idle_seconds}s (${idle_minutes}min), threshold=${BABYSIT_STUCK_THRESHOLD}s, todos=$active_todos, tasks_running=$tasks_running, error=$has_error" >> "$DEBUG_FILE"
            fi

            # Only log every 10th check to reduce noise
            if [ $((check_count % 10)) -eq 1 ]; then
                log "Babysit check #$check_count (elapsed: $((elapsed / 60))min | idle: ${idle_minutes}min | todos: $active_todos | tasks_running: $tasks_running)"
            fi

            # If tasks are in progress, reset the idle timer - Claude is working
            if [ "$tasks_running" = "true" ]; then
                babysit_last_change_time=$current_time
                if [ "$DEBUG_MODE" = true ]; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] babysit_monitor[$check_count]: tasks in progress, reset idle timer" >> "$DEBUG_FILE"
                fi
                sleep $BABYSIT_CHECK_INTERVAL
                continue
            fi

            # Decide if we need to intervene
            if [ $idle_seconds -ge $BABYSIT_STUCK_THRESHOLD ]; then
                if [ "$DEBUG_MODE" = true ]; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] babysit_monitor[$check_count]: STUCK! Sending nudge..." >> "$DEBUG_FILE"
                fi
                if [ "$has_error" = "true" ]; then
                    send_nudge "$session" "Stuck with error state for ${idle_minutes}+ minutes"
                elif [ "$active_todos" -gt 0 ]; then
                    send_nudge "$session" "Stuck with $active_todos active todos for ${idle_minutes}+ minutes"
                else
                    send_nudge "$session" "Stuck for ${idle_minutes}+ minutes with no active todos"
                fi
                # Reset after nudge
                babysit_last_change_time=$current_time
            fi

            # Wait before next check
            sleep $BABYSIT_CHECK_INTERVAL
        done

        log "Babysit monitor finished. Total checks: $check_count"
        if [ "$DEBUG_MODE" = true ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] babysit_monitor: finished, total checks=$check_count" >> "$DEBUG_FILE"
        fi
    ) &
    BABYSIT_PID=$!
    log "Babysit monitor running as PID $BABYSIT_PID"
    debug_log "start_babysit_monitor: spawned PID $BABYSIT_PID"
}

# Function to kill existing session
kill_session() {
    local session="$1"
    log "Killing existing session '$session'..."
    tmux kill-session -t "$session" 2>/dev/null
    sleep 2
}

# Function to start a new session
start_session() {
    local session="$1"
    local directory="$2"

    # Build claude command with optional model flag
    local claude_cmd="claude --dangerously-skip-permissions"
    if [ -n "$MODEL" ]; then
        claude_cmd="claude --dangerously-skip-permissions --model $MODEL"
        log "Using model: $MODEL"
    fi

    log "Starting new tmux session '$session' with Claude Code..."

    if [ -n "$directory" ]; then
        tmux new-session -d -s "$session" -c "$directory" "$claude_cmd"
    else
        tmux new-session -d -s "$session" "$claude_cmd"
    fi

    # Wait for session to be created
    local max_wait=30
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if tmux has-session -t "$session" 2>/dev/null; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if [ $waited -ge $max_wait ]; then
        log "ERROR: Failed to create tmux session"
        return 1
    fi

    # Wait for Claude to start
    log "Waiting for Claude Code to initialize..."
    local max_wait=60
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if [ "$(is_claude_running "$session")" = "true" ]; then
            log "Claude Code is running!"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
        log "Still waiting... (${waited}s)"
    done

    log "WARNING: Timed out waiting for Claude Code, but continuing..."
    return 0
}

# Function to send prompt to tmux session with retry logic
send_prompt() {
    local session="$1"
    local prompt="$2"
    local retry_count=0

    while [ $retry_count -lt $MAX_RETRIES ]; do
        log "Sending prompt to session '$session' (attempt $((retry_count + 1))/$MAX_RETRIES)..."

        if tmux send-keys -t "$session" "$prompt" 2>/dev/null; then
            log "Waiting 5 seconds before submitting..."
            sleep 5

            if tmux send-keys -t "$session" "Enter" 2>/dev/null; then
                log "Prompt submitted successfully!"
                return 0
            fi
        fi

        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $MAX_RETRIES ]; then
            log "Failed to send prompt, retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
        fi
    done

    log "ERROR: Failed to send prompt after $MAX_RETRIES attempts"
    return 1
}

# Function to monitor session and auto-submit when inactive
# timeout_minutes can be fractional (e.g., 0.5 for 30 seconds)
monitor_and_auto_submit() {
    local session="$1"
    local timeout_minutes="$2"
    # Use bc for fractional math, fallback to integer if bc not available
    local timeout_seconds
    if command -v bc &> /dev/null; then
        timeout_seconds=$(echo "$timeout_minutes * 60" | bc | cut -d. -f1)
    else
        timeout_seconds=$((${timeout_minutes%.*} * 60))
    fi
    # Ensure minimum of 1 second
    [ "$timeout_seconds" -lt 1 ] 2>/dev/null && timeout_seconds=1

    log "Starting auto-submit monitor (timeout: ${timeout_minutes}m, check interval: ${CHECK_INTERVAL}s)"
    log "Press Ctrl+C to stop monitoring"

    debug_log "monitor_and_auto_submit: started, timeout=${timeout_seconds}s, check_interval=${CHECK_INTERVAL}s"

    # Track content changes using hash comparison
    # This is simpler and more reliable than array-based history
    local last_hash=""
    local content_stable_since=$(date +%s)
    local check_count=0

    while true; do
        check_count=$((check_count + 1))

        # Capture current pane content (last 100 lines)
        local current_content=$(tmux capture-pane -t "$session" -p -S -100 2>/dev/null || echo "")
        local current_time=$(date +%s)

        # Skip if tmux capture failed
        if [[ -z "$current_content" ]]; then
            debug_log "monitor_and_auto_submit[$check_count]: tmux capture failed, skipping"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # Compute hash of current content
        local current_hash=$(content_hash "$current_content")

        debug_log "monitor_and_auto_submit[$check_count]: hash=$current_hash, last_hash=$last_hash"

        # Check if content has changed
        if [ "$current_hash" != "$last_hash" ]; then
            # Content changed, reset stable timer
            last_hash="$current_hash"
            content_stable_since=$current_time
            debug_log "monitor_and_auto_submit[$check_count]: content CHANGED, reset stable timer"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # Content unchanged, calculate stable duration
        local stable_duration=$((current_time - content_stable_since))

        debug_log "monitor_and_auto_submit[$check_count]: stable for ${stable_duration}s (need ${timeout_seconds}s)"

        # Check if Claude Code has tasks in progress - don't trigger if working
        local tasks_running=$(has_tasks_in_progress "$session")
        if [ "$tasks_running" = "true" ]; then
            debug_log "monitor_and_auto_submit[$check_count]: tasks in progress, skipping auto-submit check"
            # Reset stable timer since work is happening
            content_stable_since=$current_time
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # Check if stable long enough
        if [ $stable_duration -ge $timeout_seconds ]; then
            # Use continue prompt if set, otherwise just send Enter
            if [ -n "$CONTINUE_PROMPT" ]; then
                log "Content stable for ${stable_duration}s - Sending continue prompt..."
                debug_log "monitor_and_auto_submit[$check_count]: TRIGGERING with continue prompt: $CONTINUE_PROMPT"
                
                tmux send-keys -t "$session" "$CONTINUE_PROMPT" 2>/dev/null || true
                sleep 1
                tmux send-keys -t "$session" Enter 2>/dev/null || true
            else
                log "Content stable for ${stable_duration}s (required: ${timeout_seconds}s) - Auto-submitting with Enter..."
                debug_log "monitor_and_auto_submit[$check_count]: TRIGGERING auto-submit!"
                
                tmux send-keys -t "$session" Enter 2>/dev/null || true
            fi

            # Reset tracking after auto-submit
            last_hash=""
            content_stable_since=$(date +%s)

            debug_log "monitor_and_auto_submit[$check_count]: auto-submit sent, waiting 10s"

            # Wait for processing to begin
            sleep 10
        else
            # Show progress periodically (every 30 seconds of stability)
            local remaining=$((timeout_seconds - stable_duration))
            if [ $((stable_duration % 30)) -lt $CHECK_INTERVAL ] && [ $stable_duration -gt 0 ] && [ $remaining -gt 0 ]; then
                log "Content stable for ${stable_duration}s - will auto-submit in ${remaining}s"
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# Function to just run monitor mode
monitor_mode() {
    local session="$1"

    debug_log "monitor_mode: checking session '$session'"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        log "ERROR: Session '$session' does not exist"
        log "Start a session first, then run with --monitor"
        debug_log "monitor_mode: session not found, exiting"
        exit 1
    fi

    log "Monitor mode: watching session '$session' for inactivity"
    debug_log "monitor_mode: starting monitor_and_auto_submit with timeout=${AUTO_SUBMIT_TIMEOUT}min"
    monitor_and_auto_submit "$session" "$AUTO_SUBMIT_TIMEOUT"
}

# Main execution
main() {
    check_dependencies

    # Initialize debug logging if enabled
    init_debug

    # Handle monitor mode separately
    if [ "$MONITOR_MODE" = true ]; then
        debug_log "main: entering monitor mode"
        monitor_mode "$SESSION_NAME"
        exit 0
    fi

    validate_input

    log "Starting Infinite Claude Code session..."

    # Check if we should force restart
    if [ "$FORCE_RESTART" = true ] && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log "Force restart requested, killing existing session..."
        kill_session "$SESSION_NAME"
    fi

    # Check if session exists and is healthy
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log "Session '$SESSION_NAME' exists"

        # Check if Claude is actually running
        if [ "$(is_claude_running "$SESSION_NAME")" = "false" ]; then
            log "Claude is not running in the session, restarting..."
            kill_session "$SESSION_NAME"
        elif [ "$(is_session_idle "$SESSION_NAME" "$WAIT_TIME")" = "true" ]; then
            log "Session is idle (inactive for $WAIT_TIME+ minutes)"

            # Determine what prompt to send
            local prompt_to_send="$INITIAL_PROMPT"
            if [ -n "$CONTINUE_PROMPT" ]; then
                prompt_to_send="$CONTINUE_PROMPT"
                log "Using continue prompt: $CONTINUE_PROMPT"
            elif [ "$(has_active_todos "$SESSION_NAME")" = "true" ]; then
                log "Claude has active todo items, sending reminder..."
                prompt_to_send="Complete your todo items"
            fi

            if send_prompt "$SESSION_NAME" "$prompt_to_send"; then
                # Start babysit monitor in background (always enabled)
                start_babysit_monitor "$SESSION_NAME"

                # Start auto-submit monitor in background if enabled
                if [ "$AUTO_SUBMIT" = true ]; then
                    log "Starting auto-submit monitor in background..."
                    monitor_and_auto_submit "$SESSION_NAME" "$AUTO_SUBMIT_TIMEOUT" &
                    MONITOR_PID=$!
                    log "Auto-submit monitor running as PID $MONITOR_PID"
                fi

                log "Attaching to session..."
                exec tmux attach -t "$SESSION_NAME"
            else
                log "Failed to send prompt, try attaching manually"
                exit 1
            fi
        else
            log "Session is active (less than $WAIT_TIME minutes idle)"
            log "Wait for it to become idle, use --force to restart, or attach manually:"
            log "  tmux attach -t $SESSION_NAME"
            exit 1
        fi
    fi

    # Start new session
    if [ -n "$WORK_DIR" ]; then
        log "Working directory: $WORK_DIR"
    fi

    if start_session "$SESSION_NAME" "$WORK_DIR"; then
        # Send the initial prompt
        if send_prompt "$SESSION_NAME" "$INITIAL_PROMPT"; then
            # Start babysit monitor in background (always enabled)
            start_babysit_monitor "$SESSION_NAME"

            # Start auto-submit monitor in background if enabled
            if [ "$AUTO_SUBMIT" = true ]; then
                log "Starting auto-submit monitor in background..."
                monitor_and_auto_submit "$SESSION_NAME" "$AUTO_SUBMIT_TIMEOUT" &
                MONITOR_PID=$!
                log "Auto-submit monitor running as PID $MONITOR_PID"
            fi

            log ""
            log "Session ready! Attaching..."
            log "Detach with: Ctrl+b, then d"
            log "Monitors running in background - babysit (PID: $BABYSIT_PID)"
            if [ "$AUTO_SUBMIT" = true ]; then
                log "Monitors running in background - auto-submit (PID: $MONITOR_PID)"
            fi
            exec tmux attach -t "$SESSION_NAME"
        else
            log "ERROR: Failed to send initial prompt"
            log "Session is running but prompt was not sent"
            log "Attach manually to continue: tmux attach -t $SESSION_NAME"
            exit 1
        fi
    else
        log "ERROR: Failed to start session"
        exit 1
    fi
}

main
