#!/bin/bash

# End-to-end test for start.sh activity detection
# Tests that the monitoring and auto-submit functionality works correctly

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TEST_DIR="$SCRIPT_DIR/workspace"
DEBUG_LOG="$SCRIPT_DIR/debug.log"
TEST_LOG="$SCRIPT_DIR/test.log"
MOCK_CLAUDE="$SCRIPT_DIR/mock_claude.sh"
SESSION_NAME="test-claude-$$"
KEEPER_SESSION="test-keeper-$$"

# Export session name and check interval so start.sh uses them
export CLAUDE_SESSION_NAME="$SESSION_NAME"
export CLAUDE_CHECK_INTERVAL=1  # 1 second checks for faster tests

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "[$(date '+%H:%M:%S')] $1" | tee -a "$TEST_LOG"
}

log_ok() {
    log "${GREEN}✓ $1${NC}"
}

log_fail() {
    log "${RED}✗ $1${NC}"
}

log_info() {
    log "${YELLOW}→ $1${NC}"
}

cleanup() {
    log_info "Cleaning up..."
    
    # Kill the test session if it exists
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    
    # Kill the keeper session (this keeps tmux server alive during tests)
    tmux kill-session -t "$KEEPER_SESSION" 2>/dev/null || true
    
    # Remove mock claude
    rm -f "$MOCK_CLAUDE" 2>/dev/null || true
    
    # Clean up test workspace (but keep logs for inspection)
    rm -rf "$TEST_DIR" 2>/dev/null || true
    
    log_info "Cleanup complete. Logs preserved at:"
    log_info "  Debug log: $DEBUG_LOG"
    log_info "  Test log:  $TEST_LOG"
}

# Set up trap for cleanup on exit
trap cleanup EXIT

# Ensure tmux server is running by creating a keeper session
ensure_tmux_server() {
    # Start tmux server if not running
    tmux start-server 2>/dev/null || true
    
    if ! tmux has-session -t "$KEEPER_SESSION" 2>/dev/null; then
        tmux new-session -d -s "$KEEPER_SESSION" "sleep 3600"
        log_info "Created keeper session: $KEEPER_SESSION"
    fi
    
    # Debug: show all sessions
    log_info "Active tmux sessions: $(tmux list-sessions 2>/dev/null | tr '\n' ' ' || echo 'none')"
}

# Create test workspace
setup() {
    log_info "Setting up test environment..."
    
    # Clean previous runs
    rm -f "$DEBUG_LOG" "$TEST_LOG" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    
    # Start tmux server with keeper session
    ensure_tmux_server
    
    mkdir -p "$TEST_DIR"
    
    # Create a mock claude script that simulates activity
    cat > "$MOCK_CLAUDE" << 'MOCK_EOF'
#!/bin/bash
# Mock Claude that simulates typing and then goes idle

echo "Mock Claude Code started"
echo "Waiting for input..."

# Read input (the prompt)
read -r prompt
echo "Received prompt: $prompt"

# Simulate some activity
for i in 1 2 3; do
    echo "Working on task... step $i"
    sleep 1
done

echo "Task complete. Waiting for more input..."

# Go idle - just wait for more input
while true; do
    read -r input
    if [ -n "$input" ]; then
        echo "Received: $input"
        for i in 1 2; do
            echo "Continuing work... step $i"
            sleep 1
        done
        echo "Done. Waiting..."
    fi
done
MOCK_EOF
    chmod +x "$MOCK_CLAUDE"
    
    log_ok "Test environment ready"
}

# Test 1: Verify debug mode writes to file
test_debug_mode() {
    log_info "TEST 1: Verify --debug flag writes to debug file"
    
    rm -f "$DEBUG_LOG" 2>/dev/null || true
    ensure_tmux_server
    
    # Create a dummy session first so monitor mode doesn't fail
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    tmux new-session -d -s "$SESSION_NAME" "sleep 30"
    sleep 1
    
    # Run start.sh in monitor mode briefly with debug
    timeout 3 bash -c "
        export CLAUDE_SESSION_NAME='$SESSION_NAME'
        export CLAUDE_CHECK_INTERVAL=1
        '$REPO_DIR/start.sh' --debug '$DEBUG_LOG' --monitor 2>&1
    " 2>&1 || true
    
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    
    # Check if debug file was created with header
    if [ -f "$DEBUG_LOG" ] && grep -q "Infinite Claude Code Debug Log" "$DEBUG_LOG"; then
        log_ok "Debug file created with header"
        return 0
    else
        log_fail "Debug file not created or missing header"
        [ -f "$DEBUG_LOG" ] && cat "$DEBUG_LOG"
        return 1
    fi
}

# Test 2: Test fractional timeout parsing
test_fractional_timeout() {
    log_info "TEST 2: Verify fractional timeout is accepted"
    
    rm -f "$DEBUG_LOG" 2>/dev/null || true
    ensure_tmux_server
    
    # Create a simple tmux session for testing
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    tmux new-session -d -s "$SESSION_NAME" "echo 'test'; sleep 30"
    sleep 1
    
    # Run monitor with fractional timeout
    timeout 8 bash -c "
        export CLAUDE_SESSION_NAME='$SESSION_NAME'
        export CLAUDE_CHECK_INTERVAL=1
        '$REPO_DIR/start.sh' --debug '$DEBUG_LOG' --auto-submit-timeout 0.1 --monitor 2>&1
    " 2>&1 || true
    
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    
    # Check if the timeout was parsed (should be 6 seconds for 0.1 minutes)
    if [ -f "$DEBUG_LOG" ] && grep -q "timeout=" "$DEBUG_LOG"; then
        local timeout_val
        timeout_val=$(grep "timeout=" "$DEBUG_LOG" | head -1 | grep -oE 'timeout=[0-9]+' | cut -d= -f2) || timeout_val=0
        if [ -n "$timeout_val" ] && [ "$timeout_val" -le 10 ]; then
            log_ok "Fractional timeout parsed correctly (${timeout_val}s)"
            return 0
        fi
    fi
    
    log_fail "Fractional timeout not parsed correctly"
    cat "$DEBUG_LOG" 2>/dev/null || echo "No debug log"
    return 1
}

# Test 3: Test content-based activity detection
test_activity_detection() {
    log_info "TEST 3: Verify content-based activity detection"
    
    rm -f "$DEBUG_LOG" 2>/dev/null || true
    ensure_tmux_server
    
    # Make sure no old session exists
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    sleep 1
    
    # Create a helper script for changing output
    local output_script="$SCRIPT_DIR/output_generator.sh"
    cat > "$output_script" << 'GENEOF'
#!/bin/bash
for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "Output line $i at $(date +%H:%M:%S)"
    sleep 1
done
echo "Now idle..."
sleep 120
GENEOF
    chmod +x "$output_script"
    
    # Create session using the script
    tmux new-session -d -s "$SESSION_NAME" "$output_script"
    
    # Wait and verify session exists
    sleep 2
    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log_fail "Failed to create tmux session"
        log_info "Trying to list sessions..."
        tmux list-sessions 2>&1 || echo "No sessions"
        return 1
    fi
    log_info "Session '$SESSION_NAME' created successfully"
    
    # Run monitor briefly (with 1 second check interval)
    timeout 12 bash -c "
        export CLAUDE_SESSION_NAME='$SESSION_NAME'
        export CLAUDE_CHECK_INTERVAL=1
        '$REPO_DIR/start.sh' --debug '$DEBUG_LOG' --auto-submit-timeout 0.5 --monitor 2>&1
    " 2>&1 || true
    
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -f "$output_script" 2>/dev/null || true
    
    # Check debug log for content change detection
    if [ -f "$DEBUG_LOG" ]; then
        local changed_count
        local stable_count
        changed_count=$(grep -c "content CHANGED" "$DEBUG_LOG" 2>/dev/null) || changed_count=0
        stable_count=$(grep -c "stable for" "$DEBUG_LOG" 2>/dev/null) || stable_count=0
        
        log_info "Content changes detected: $changed_count"
        log_info "Stability checks: $stable_count"
        
        if [ "$changed_count" -gt 0 ]; then
            log_ok "Activity detection is working - detected content changes"
            return 0
        fi
    fi
    
    log_fail "Activity detection not working properly"
    echo "--- Debug log contents ---"
    cat "$DEBUG_LOG" 2>/dev/null || echo "No debug log"
    echo "--- End debug log ---"
    return 1
}

# Test 4: Test auto-submit trigger
test_auto_submit() {
    log_info "TEST 4: Verify auto-submit triggers after idle period"
    
    rm -f "$DEBUG_LOG" 2>/dev/null || true
    ensure_tmux_server
    
    # Make sure no old session exists  
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    sleep 1
    
    # Create a session that goes idle immediately
    tmux new-session -d -s "$SESSION_NAME" "
        echo 'Initial output - going idle now'
        sleep 120
    "
    sleep 2  # Give session time to display initial output
    
    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log_fail "Failed to create tmux session for test 4"
        return 1
    fi
    
    # Run monitor with very short timeout (0.1 min = 6 seconds)
    timeout 15 bash -c "
        export CLAUDE_SESSION_NAME='$SESSION_NAME'
        export CLAUDE_CHECK_INTERVAL=1
        '$REPO_DIR/start.sh' --debug '$DEBUG_LOG' --auto-submit-timeout 0.1 --monitor 2>&1
    " 2>&1 || true
    
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    
    # Check if auto-submit was triggered
    if [ -f "$DEBUG_LOG" ] && grep -q "TRIGGERING auto-submit" "$DEBUG_LOG"; then
        log_ok "Auto-submit triggered correctly"
        return 0
    fi
    
    log_fail "Auto-submit did not trigger"
    echo "--- Debug log contents ---"
    cat "$DEBUG_LOG" 2>/dev/null || echo "No debug log"
    echo "--- End debug log ---"
    return 1
}

# Main test runner
main() {
    echo ""
    echo "========================================"
    echo "  Infinite Claude Code - E2E Tests"
    echo "========================================"
    echo ""
    
    setup
    
    local passed=0
    local failed=0
    
    # Run tests
    if test_debug_mode; then
        ((passed++))
    else
        ((failed++))
    fi
    
    if test_fractional_timeout; then
        ((passed++))
    else
        ((failed++))
    fi
    
    if test_activity_detection; then
        ((passed++))
    else
        ((failed++))
    fi
    
    if test_auto_submit; then
        ((passed++))
    else
        ((failed++))
    fi
    
    echo ""
    echo "========================================"
    echo "  Results: $passed passed, $failed failed"
    echo "========================================"
    echo ""
    
    if [ $failed -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"
