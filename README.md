# Infinite Claude Code

A streamlined script to manage Claude Code sessions with built-in babysitting and auto-continuation features.

## Overview

This project provides a single script `start.sh` that:
- Starts Claude Code sessions with automatic prompt submission
- Includes built-in babysitting to prevent stuck sessions (always enabled)
- Supports continue prompts for ongoing work
- Monitors for session health and intervenes when needed
- Content-based activity detection using MD5 hashing

## Features

- **Session Management**: Automatic tmux session handling for Claude Code
- **Built-in Babysitting**: Always-on monitoring to detect and recover stuck sessions
- **Content-Based Activity Detection**: Uses MD5 hashing of pane content to accurately detect when Claude is idle (not just window focus)
- **Robust Auto-Submit**: Monitors for content stability before submitting prompts
- **Continue Prompts**: Automatically sends follow-up prompts when session becomes idle
- **Model Selection**: Choose which Claude model to use (haiku, sonnet, opus)
- **Debug Mode**: Detailed logging to file for troubleshooting
- **Fractional Timeouts**: Support for sub-minute timeouts (e.g., 0.5 for 30 seconds)
- **Monitor Mode**: Run in monitoring-only mode without providing prompts

## Installation

1. Ensure you have the required dependencies:
   - `tmux`
   - `claude` (Claude Code CLI)

2. Make the script executable:
   ```bash
   chmod +x start.sh
   ```

## Usage

### Starting a New Session

```bash
./start.sh "Refactor to TypeScript"
```

### Continuing Work on Existing Session

```bash
./start.sh "Refactor to TypeScript" --continue-prompt "Keep working"
```

### Using a Specific Model

```bash
./start.sh --model haiku "Write a simple function"
./start.sh --model sonnet "Implement complex algorithm"
```

### Debug Mode

```bash
# Enable debug logging (default: /tmp/infinite-claude-debug.log)
./start.sh --debug "My prompt"

# Custom debug file
./start.sh --debug /tmp/my-debug.log "My prompt"

# Monitor debug output in another terminal
tail -f /tmp/infinite-claude-debug.log
```

### Advanced Options

```bash
# Change directory before starting
./start.sh --pwd /path/to/project "Add error handling"

# Custom auto-submit timeout (supports fractions)
./start.sh --auto-submit-timeout 0.5 "Quick task"  # 30 seconds
./start.sh --auto-submit-timeout 2 "Longer task"   # 2 minutes

# Disable auto-submit
./start.sh --no-auto-submit "Manual prompt"

# Monitor existing session only
./start.sh --monitor

# Force restart existing session
./start.sh --force "New prompt"
```

## How Activity Detection Works

The script uses **content-based detection** to determine when Claude is idle:

1. **MD5 Hashing**: Captures the tmux pane content and computes its hash
2. **Change Detection**: Compares current hash with previous hash
3. **Stability Timer**: Tracks how long content has been unchanged
4. **Auto-Submit**: When content is stable for the timeout period, sends the continue prompt

This is more accurate than using tmux's `#{window_activity}` which only tracks window focus.

### Debug Log Output

With `--debug` enabled, you'll see entries like:
```
[2026-01-27 01:53:04] monitor_and_auto_submit[12]: hash=abc123..., last_hash=def456...
[2026-01-27 01:53:04] monitor_and_auto_submit[12]: content CHANGED, reset stable timer
[2026-01-27 01:53:14] monitor_and_auto_submit[17]: stable for 10s (need 10s)
[2026-01-27 01:53:14] monitor_and_auto_submit[17]: TRIGGERING with continue prompt: Keep working
```

## Built-in Babysitting

The babysit functionality is always enabled and runs in the background:

- **Check Interval**: Every 5 minutes
- **Stuck Detection**: Sessions idle for 15+ minutes (content unchanged)
- **Auto-Recovery**: Sends wake-up prompts or Ctrl+C to unstuck sessions
- **Runtime Limit**: Monitors for up to 8 hours

## Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `--pwd DIRECTORY` | Change to directory before running Claude Code | Current directory |
| `--wait-time MINUTES` | Wait time before considering session idle | 1 minute |
| `--auto-submit-timeout MIN` | Inactivity timeout for auto-submit (supports fractions) | 1 minute |
| `--no-auto-submit` | Disable auto-submit feature | Auto-submit ON |
| `--continue-prompt PROMPT` | Prompt to send when session becomes idle | None |
| `--model MODEL` | Claude model to use (haiku, sonnet, opus) | Default |
| `--debug [FILE]` | Enable debug logging | Disabled |
| `--monitor` | Monitor mode only | Disabled |
| `--force, -f` | Force restart existing session | Disabled |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `CLAUDE_SESSION_NAME` | Override the tmux session name |
| `CLAUDE_CHECK_INTERVAL` | Override check interval in seconds |

## Examples

### Basic Usage
```bash
./start.sh "Create a function to calculate fibonacci numbers"
```

### Project-Specific Work
```bash
./start.sh --pwd ~/projects/my-app "Add error handling to the login function"
```

### Long-Running Tasks with Continuation
```bash
./start.sh "Refactor the entire codebase" --continue-prompt "Continue the refactoring work"
```

### Fast Iteration with Haiku
```bash
./start.sh --model haiku --auto-submit-timeout 0.17 "Write poems" --continue-prompt "Write another poem"
```

### Debugging Issues
```bash
./start.sh --debug --auto-submit-timeout 0.5 "Test task"
# In another terminal:
tail -f /tmp/infinite-claude-debug.log
```

### Monitoring Only
```bash
./start.sh --monitor
```

## Testing

Run the end-to-end tests:

```bash
# Mock tests (no tokens used)
./test/e2e_test.sh

# Real tests with Claude (uses tokens)
./test/real_e2e_test.sh
```

## Troubleshooting

### Common Issues

1. **"Missing dependencies"**: Install `tmux` and `claude` CLI
2. **Session already exists**: Use `--force` to restart or `--continue-prompt` to continue
3. **Stuck sessions**: The built-in babysitter will automatically detect and recover stuck sessions
4. **Activity not detected**: Enable `--debug` to see content hash changes

### Debug Mode

Enable `--debug` to write detailed logs showing:
- Content hash changes
- Stability duration
- Auto-submit triggers
- Babysit monitor status

## Contributing

Feel free to submit issues and enhancement requests!
