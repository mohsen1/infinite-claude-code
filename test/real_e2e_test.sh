#!/bin/bash

# Real end-to-end test using actual Claude
# This will consume tokens!

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TEST_DIR="$SCRIPT_DIR/real_workspace"
DEBUG_LOG="$SCRIPT_DIR/real_debug.log"
SESSION_NAME="real-test-claude-$$"

# Export for start.sh
export CLAUDE_SESSION_NAME="$SESSION_NAME"
export CLAUDE_CHECK_INTERVAL=2

echo "========================================"
echo "  Real E2E Test - Write a Long Poem"
echo "========================================"
echo ""
echo "Session: $SESSION_NAME"
echo "Debug log: $DEBUG_LOG"
echo "Test dir: $TEST_DIR"
echo ""

cleanup() {
    echo ""
    echo "========== CLEANUP =========="
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    echo "Session killed."
    echo ""
    echo "=== Final README.md ==="
    cat "$TEST_DIR/README.md" 2>/dev/null || echo "(not found)"
    echo ""
    echo "Debug log: $DEBUG_LOG"
}
trap cleanup EXIT

# Setup
rm -rf "$TEST_DIR" 2>/dev/null || true
mkdir -p "$TEST_DIR"
rm -f "$DEBUG_LOG" 2>/dev/null || true

# Create initial README
cat > "$TEST_DIR/README.md" << 'EOF'
# Poetry Collection

Add poems below:

EOF

echo "Initial README.md created."
echo ""
echo "Will run with:"
echo "  - model: haiku"
echo "  - auto-submit-timeout: 0.17 min (10 seconds)"
echo "  - Target: 4 auto-submit iterations"
echo "  - Expected: 4 different poems with unique titles"
echo ""

cd "$TEST_DIR"

# Start in background - use tmux directly so we can monitor
tmux new-session -d -s "$SESSION_NAME" -c "$TEST_DIR" "claude --dangerously-skip-permissions --model haiku"
sleep 3

# Verify claude started
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "ERROR: Failed to create tmux session"
    exit 1
fi

echo "Claude session started. Sending initial prompt..."

# Send initial prompt
tmux send-keys -t "$SESSION_NAME" "Write a poem (at least 12 lines) with a creative title about 'The First Line of Code'. Add it to README.md under a markdown heading with the poem's title. Make it inspiring!" Enter
sleep 2

# Start our monitor in background with continue prompt for new poems
"$REPO_DIR/start.sh" \
    --debug "$DEBUG_LOG" \
    --auto-submit-timeout 0.17 \
    --continue-prompt "Write another poem under a new heading" \
    --monitor &
MONITOR_PID=$!

echo "Monitor started (PID: $MONITOR_PID)"
echo ""
echo "Waiting for 3 auto-submit cycles..."
echo ""

# Monitor for auto-submits
TARGET_SUBMITS=4
MAX_WAIT=300  # 5 minutes max
ELAPSED=0
LAST_SUBMITS=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    
    # Count auto-submits
    SUBMITS=0
    if [ -f "$DEBUG_LOG" ]; then
        SUBMITS=$(grep -c "TRIGGERING auto-submit" "$DEBUG_LOG" 2>/dev/null) || SUBMITS=0
    fi
    
    # Show progress
    CHANGES=$(grep -c "content CHANGED" "$DEBUG_LOG" 2>/dev/null) || CHANGES=0
    README_LINES=$(wc -l < "$TEST_DIR/README.md" 2>/dev/null) || README_LINES=0
    
    echo "[${ELAPSED}s] Changes: $CHANGES | Auto-submits: $SUBMITS/$TARGET_SUBMITS | README lines: $README_LINES"
    
    # Show when auto-submit happens
    if [ "$SUBMITS" -gt "$LAST_SUBMITS" ]; then
        echo "  >>> AUTO-SUBMIT #$SUBMITS triggered!"
        LAST_SUBMITS=$SUBMITS
    fi
    
    # Check if we reached target
    if [ "$SUBMITS" -ge "$TARGET_SUBMITS" ]; then
        echo ""
        echo "SUCCESS: Reached $TARGET_SUBMITS auto-submit cycles!"
        break
    fi
done

# Kill monitor
kill $MONITOR_PID 2>/dev/null || true

echo ""
echo "========== RESULTS =========="
echo ""

if [ -f "$DEBUG_LOG" ]; then
    FINAL_SUBMITS=$(grep -c "TRIGGERING auto-submit" "$DEBUG_LOG" 2>/dev/null) || FINAL_SUBMITS=0
    FINAL_CHANGES=$(grep -c "content CHANGED" "$DEBUG_LOG" 2>/dev/null) || FINAL_CHANGES=0
    echo "Total content changes detected: $FINAL_CHANGES"
    echo "Total auto-submits: $FINAL_SUBMITS"
fi

README_LINES=$(wc -l < "$TEST_DIR/README.md" 2>/dev/null) || README_LINES=0
echo "Final README.md lines: $README_LINES"

if [ "$README_LINES" -gt 10 ]; then
    echo ""
    echo "SUCCESS: Long poem written! ($README_LINES lines)"
else
    echo ""
    echo "NOTE: README has only $README_LINES lines"
fi
