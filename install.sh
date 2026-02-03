#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_PROJECT="$SCRIPT_DIR/aws-auth-monitor-rs"
CONFIG_FILE=~/.config/aws-auth-monitor.json
BINARY=~/.local/bin/aws-auth-monitor
SERVICE_FILE=~/.config/systemd/user/aws-auth-monitor.service
STATUS_FILE=~/.aws/auth-status

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
    if systemctl --user is-active --quiet aws-auth-monitor 2>/dev/null; then
        systemctl --user stop aws-auth-monitor
        echo "  Stopped aws-auth-monitor.service"
    fi
    if systemctl --user is-enabled --quiet aws-auth-monitor 2>/dev/null; then
        systemctl --user disable aws-auth-monitor
        echo "  Disabled aws-auth-monitor.service"
    fi

    # Remove files
    if [ -f "$SERVICE_FILE" ]; then
        rm "$SERVICE_FILE"
        systemctl --user daemon-reload
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
    if systemctl --user is-active --quiet aws-auth-monitor 2>/dev/null; then
        systemctl --user stop aws-auth-monitor
        echo "  Stopped aws-auth-monitor.service"
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
    echo "Config file: $CONFIG_FILE"
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
