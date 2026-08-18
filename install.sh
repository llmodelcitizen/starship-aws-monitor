#!/usr/bin/env bash
#
# Installs aws-auth-monitor: builds the Rust binary, installs the config,
# and starts the monitor in the background under the platform's supervisor.
#
# Linux (systemd): installs a user service, managed via systemctl.
# macOS (launchd): installs a LaunchAgent, managed via launchctl.
#                  Plist: ~/Library/LaunchAgents/com.llmodelcitizen.aws-auth-monitor.plist
#                  Log:   ~/Library/Logs/aws-auth-monitor.log
# Otherwise:       runs via nohup with a PID file for lifecycle management.
#                  PID file: ~/.local/share/aws-auth-monitor/pid
#                  Log file: ~/.local/share/aws-auth-monitor/output.log
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_PROJECT="$SCRIPT_DIR/aws-auth-monitor-rs"
CONFIG_FILE=~/.config/aws-auth-monitor.json
BINARY=~/.local/bin/aws-auth-monitor
STATUS_FILE=~/.aws/auth-status

# systemd
SERVICE_FILE=~/.config/systemd/user/aws-auth-monitor.service

# launchd
LAUNCHD_LABEL=com.llmodelcitizen.aws-auth-monitor
PLIST_FILE=~/Library/LaunchAgents/$LAUNCHD_LABEL.plist
LAUNCHD_LOG=~/Library/Logs/aws-auth-monitor.log
LAUNCHD_DOMAIN="gui/$(id -u)"

# nohup fallback
PID_FILE=~/.local/share/aws-auth-monitor/pid
NOHUP_LOG=~/.local/share/aws-auth-monitor/output.log

has_systemd() {
    command -v systemctl &> /dev/null && systemctl --user show-environment &> /dev/null
}

# launchd is usable when we're on macOS and the per-user GUI domain is
# reachable (it isn't for e.g. an SSH-only login with no window session).
has_launchd() {
    [ "$(uname -s)" = "Darwin" ] \
        && command -v launchctl &> /dev/null \
        && launchctl print "$LAUNCHD_DOMAIN" &> /dev/null
}

launchd_loaded() {
    launchctl print "$LAUNCHD_DOMAIN/$LAUNCHD_LABEL" &> /dev/null
}

usage() {
    echo "Usage: $(basename "$0") [uninstall]"
    echo
    echo "Commands:"
    echo "  (none)      Install aws-auth-monitor"
    echo "  uninstall   Remove aws-auth-monitor"
}

# Stop whatever is currently running the monitor: the supervisor's instance
# (if any) plus any leftover nohup instance from a previous install.
stop_running() {
    if has_systemd; then
        if systemctl --user is-active --quiet aws-auth-monitor 2>/dev/null; then
            systemctl --user stop aws-auth-monitor
            echo "  Stopped aws-auth-monitor.service"
        fi
    elif has_launchd; then
        if launchd_loaded; then
            launchctl bootout "$LAUNCHD_DOMAIN/$LAUNCHD_LABEL"
            echo "  Unloaded $LAUNCHD_LABEL"
        fi
    fi

    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            echo "  Stopped aws-auth-monitor (PID $pid)"
        fi
        rm "$PID_FILE"
    fi
}

do_uninstall() {
    echo "Uninstalling aws-auth-monitor..."

    stop_running

    if has_systemd && systemctl --user is-enabled --quiet aws-auth-monitor 2>/dev/null; then
        systemctl --user disable aws-auth-monitor
        echo "  Disabled aws-auth-monitor.service"
    fi

    # Remove files
    if [ -f "$SERVICE_FILE" ]; then
        rm "$SERVICE_FILE"
        if has_systemd; then
            systemctl --user daemon-reload
        fi
        echo "  Removed $SERVICE_FILE"
    fi
    if [ -f "$PLIST_FILE" ]; then
        rm "$PLIST_FILE"
        echo "  Removed $PLIST_FILE"
    fi
    for log in "$LAUNCHD_LOG" "$NOHUP_LOG"; do
        if [ -f "$log" ]; then
            rm "$log"
            echo "  Removed $log"
        fi
    done
    if [ -f "$BINARY" ]; then
        rm "$BINARY"
        echo "  Removed $BINARY"
    fi
    if [ -f "$STATUS_FILE" ]; then
        rm "$STATUS_FILE"
        echo "  Removed $STATUS_FILE"
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

    # Stop the running instance before replacing the binary. On Linux this
    # avoids "text file busy"; on macOS overwriting a running binary in place
    # invalidates its code signature and kills the process.
    stop_running

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

        systemctl --user daemon-reload
        systemctl --user enable --now aws-auth-monitor
        echo "  Enabled and started aws-auth-monitor.service"

        echo "Done. Check status with: systemctl --user status aws-auth-monitor"
    elif has_launchd; then
        # Install the launchd agent. launchd doesn't expand ~ or env vars in
        # plist values, so bake the absolute home path into the plist.
        mkdir -p ~/Library/LaunchAgents ~/Library/Logs
        sed "s|@HOME@|$HOME|g" "$SCRIPT_DIR/aws-auth-monitor.plist" > "$PLIST_FILE"
        echo "  Installed $PLIST_FILE"

        # Clear any prior `launchctl disable`, then load; RunAtLoad starts it.
        launchctl enable "$LAUNCHD_DOMAIN/$LAUNCHD_LABEL"
        launchctl bootstrap "$LAUNCHD_DOMAIN" "$PLIST_FILE"
        echo "  Loaded and started $LAUNCHD_LABEL"

        echo "Done. Check status with: launchctl print $LAUNCHD_DOMAIN/$LAUNCHD_LABEL"
        echo "  Logs: $LAUNCHD_LOG"
    else
        # No supervisor — run with nohup and track the PID
        mkdir -p "$(dirname "$PID_FILE")"
        nohup "$BINARY" >> "$NOHUP_LOG" 2>&1 &
        echo $! > "$PID_FILE"
        echo "  Started aws-auth-monitor in background (PID $!)"
        echo "  Logs: $NOHUP_LOG"
        echo "  (No systemd or launchd found; the monitor will not survive a reboot.)"
    fi
    echo "Config file: $CONFIG_FILE"

    # Shell integration hint
    RC_FILE=~/.bashrc
    case "${SHELL:-}" in
        */zsh) RC_FILE=~/.zshrc ;;
    esac
    SHELL_INIT='eval "$(aws-auth-monitor shell-init bash)"'
    if ! grep -qF "$SHELL_INIT" "$RC_FILE" 2>/dev/null; then
        echo
        echo "To add the 'aso' (AWS SSO toggle) function to your shell, add this to $RC_FILE:"
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
