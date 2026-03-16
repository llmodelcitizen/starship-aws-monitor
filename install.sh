#!/usr/bin/env bash
#
# Installs aws-auth-monitor: builds the Rust binary, installs the config,
# and starts the monitor in the background.
#
# With systemd:    installs a user service, managed via systemctl.
# Without systemd: runs via nohup with a PID file for lifecycle management.
#                  PID file: ~/.local/share/aws-auth-monitor/pid
#                  Log file: ~/.local/share/aws-auth-monitor/output.log
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_PROJECT="$SCRIPT_DIR/aws-auth-monitor-rs"
CONFIG_FILE=~/.config/aws-auth-monitor.json
BINARY=~/.local/bin/aws-auth-monitor
SERVICE_FILE=~/.config/systemd/user/aws-auth-monitor.service
STATUS_FILE=~/.aws/auth-status
PID_FILE=~/.local/share/aws-auth-monitor/pid

has_systemd() {
    command -v systemctl &> /dev/null && systemctl --user show-environment &> /dev/null
}

usage() {
    echo "Usage: $(basename "$0") [uninstall]"
    echo
    echo "Commands:"
    echo "  (none)      Install aws-auth-monitor"
    echo "  uninstall   Remove aws-auth-monitor"
}

do_uninstall() {
    echo "Uninstalling aws-auth-monitor..."

    # Stop and disable service
    if has_systemd; then
        if systemctl --user is-active --quiet aws-auth-monitor 2>/dev/null; then
            systemctl --user stop aws-auth-monitor
            echo "  Stopped aws-auth-monitor.service"
        fi
        if systemctl --user is-enabled --quiet aws-auth-monitor 2>/dev/null; then
            systemctl --user disable aws-auth-monitor
            echo "  Disabled aws-auth-monitor.service"
        fi
    elif [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            echo "  Stopped aws-auth-monitor (PID $pid)"
        fi
        rm "$PID_FILE"
    fi

    # Remove files
    if [ -f "$SERVICE_FILE" ]; then
        rm "$SERVICE_FILE"
        if has_systemd; then
            systemctl --user daemon-reload
        fi
        echo "  Removed $SERVICE_FILE"
    fi
    if [ -f "$BINARY" ]; then
        rm "$BINARY"
        echo "  Removed $BINARY"
    fi
    if [ -f "$STATUS_FILE" ]; then
        rm "$STATUS_FILE"
        echo "  Removed $STATUS_FILE"
    fi
    if [ -f "$PID_FILE" ]; then
        rm "$PID_FILE"
        echo "  Removed $PID_FILE"
    fi
    if [ -f "$CONFIG_FILE" ]; then
        backup="${CONFIG_FILE}.$(date +%Y%m%d-%H%M%S)"
        mv "$CONFIG_FILE" "$backup"
        echo "  Backed up $CONFIG_FILE to $backup"
    fi

    echo "Done."
}

do_install() {
    echo "Installing aws-auth-monitor..."

    # Check for cargo
    if ! command -v cargo &> /dev/null; then
        echo "Error: cargo not found. Install Rust from https://rustup.rs"
        exit 1
    fi

    # Build the Rust binary
    echo "  Building Rust binary..."
    (cd "$RUST_PROJECT" && cargo build --release)

    # Stop service if running (avoids "text file busy" error)
    if has_systemd && systemctl --user is-active --quiet aws-auth-monitor 2>/dev/null; then
        systemctl --user stop aws-auth-monitor
        echo "  Stopped aws-auth-monitor.service"
    elif [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            echo "  Stopped aws-auth-monitor (PID $pid)"
        fi
    fi

    # Install the binary
    mkdir -p ~/.local/bin
    cp "$RUST_PROJECT/target/release/aws-auth-monitor" "$BINARY"
    chmod +x "$BINARY"
    echo "  Installed $BINARY"

    # Install default config (if not present)
    if [ ! -f "$CONFIG_FILE" ]; then
        cp "$SCRIPT_DIR/aws-auth-monitor.json" "$CONFIG_FILE"
        echo "  Installed $CONFIG_FILE"
    else
        echo "  Keeping existing config: $CONFIG_FILE"
        echo "  (To reset to defaults, run: $(basename "$0") uninstall && $(basename "$0"))"
    fi

    if has_systemd; then
        # Install the systemd user service
        mkdir -p ~/.config/systemd/user
        cp "$SCRIPT_DIR/aws-auth-monitor.service" "$SERVICE_FILE"
        echo "  Installed $SERVICE_FILE"

        # Reload and enable/restart
        systemctl --user daemon-reload
        if systemctl --user is-active --quiet aws-auth-monitor; then
            systemctl --user restart aws-auth-monitor
            echo "  Restarted aws-auth-monitor.service"
        else
            systemctl --user enable --now aws-auth-monitor
            echo "  Enabled and started aws-auth-monitor.service"
        fi

        echo "Done. Check status with: systemctl --user status aws-auth-monitor"
    else
        # No systemd — run with nohup and track the PID
        mkdir -p "$(dirname "$PID_FILE")"
        LOG_FILE=~/.local/share/aws-auth-monitor/output.log
        nohup "$BINARY" >> "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
        echo "  Started aws-auth-monitor in background (PID $!)"
        echo "  Logs: $LOG_FILE"
    fi
    echo "Config file: $CONFIG_FILE"

    # Shell integration hint
    SHELL_INIT='eval "$(aws-auth-monitor shell-init bash)"'
    if ! grep -qF "$SHELL_INIT" ~/.bashrc 2>/dev/null; then
        echo
        echo "To add the 'aso' (AWS SSO toggle) function to your shell, add this to ~/.bashrc:"
        echo "  $SHELL_INIT"
        echo
        echo "aso defaults to --use-device-code for SSO login. For PKCE (localhost redirect), set:"
        echo "  export AWS_SSO_LOGIN_METHOD=pkce"
    fi
}

case "${1:-}" in
    "")
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "Unknown command: $1"
        usage
        exit 1
        ;;
esac
