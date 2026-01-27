# Infinite Claude Code

A streamlined script to manage Claude Code sessions with built-in babysitting and auto-continuation features.

## Overview

This project provides a single script `start.sh` that:
- Starts Claude Code sessions with automatic prompt submission
- Includes built-in babysitting to prevent stuck sessions (always enabled)
- Supports continue prompts for ongoing work
- Monitors for session health and intervenes when needed

## Features

- **Session Management**: Automatic tmux session handling for Claude Code
- **Built-in Babysitting**: Always-on monitoring to detect and recover stuck sessions
- **Robust Auto-Submit**: Advanced change detection that ensures screen stability over time before submitting prompts
- **Continue Prompts**: Send follow-up prompts to existing sessions
- **Flexible Configuration**: Customizable timeouts and retry logic
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

### Advanced Options

```bash
# Change directory before starting
./start.sh --pwd /path/to/project "Add error handling"

# Custom auto-submit timeout
./start.sh --auto-submit-timeout 2 "Work on this task"

# Disable auto-submit
./start.sh --no-auto-submit "Manual prompt"

# Monitor existing session only
./start.sh --monitor

# Force restart existing session
./start.sh --force "New prompt"
```

## How to Know When Claude Code is Ready

**Important**: Claude Code is ready to receive a new prompt when **no characters are changing on the screen**. This indicates that:

1. Claude Code has finished processing the current prompt
2. All output has been displayed
3. The session is waiting for new input

### Visual Indicators

- **Ready**: Screen is stable, cursor is blinking, no new text appearing
- **Processing**: Characters/text is still being written to the screen
- **Stuck**: Screen frozen with incomplete output (babysitter will detect and intervene)

### Auto-Submit Behavior

The script automatically detects when Claude Code is ready by monitoring for screen stability over time. It maintains a history of recent screen captures and only considers the session ready when the content has been completely unchanged for the full timeout period. This prevents false triggers from temporary pauses in output.

## Built-in Babysitting

The babysit functionality is always enabled and runs in the background:

- **Check Interval**: Every 5 minutes
- **Stuck Detection**: Sessions idle for 15+ minutes
- **Auto-Recovery**: Sends wake-up prompts or Ctrl+C to unstuck sessions
- **Runtime Limit**: Monitors for up to 8 hours

## Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `--pwd DIRECTORY` | Change to directory before running Claude Code | Current working directory |
| `--wait-time MINUTES` | Wait time before considering session idle | 1 minute |
| `--auto-submit-timeout MIN` | Inactivity timeout for auto-submit | 1 minute |
| `--no-auto-submit` | Disable auto-submit feature | Enabled |
| `--continue-prompt PROMPT` | Prompt to send when session becomes idle | None |
| `--monitor` | Monitor mode only | Disabled |
| `--force, -f` | Force restart existing session | Disabled |

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

### Monitoring Only
```bash
./start.sh --monitor
```

## Troubleshooting

### Common Issues

1. **"Missing dependencies"**: Install `tmux` and `claude` CLI
2. **Session already exists**: Use `--force` to restart or `--continue-prompt` to continue
3. **Stuck sessions**: The built-in babysitter will automatically detect and recover stuck sessions

### Logs

- Babysit actions are logged to stdout with timestamps
- Session activity is monitored continuously

## Contributing

Feel free to submit issues and enhancement requests!