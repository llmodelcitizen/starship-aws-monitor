# AWS Authentication Monitor for Starship

A lightweight service that monitors AWS authentication status for display in your shell prompt via [Starship](https://starship.rs/). Runs as a systemd user service on Linux and a launchd agent on macOS.

## Why?

The built-in Starship `[aws]` module shows AWS info even when credentials are expired. This service solves that by:

- Running as a background service under systemd (Linux) or launchd (macOS), so the prompt never waits on AWS
- Checking authentication via STS `GetCallerIdentity` every 60 seconds
- Writing status to `~/.aws/auth-status` for Starship to read
- Only displaying AWS info when actually authenticated

<br>

<img width="680" height="52" alt="image" src="https://github.com/user-attachments/assets/4aee17d1-792e-4dc9-b9c4-a4eac1996e3e" />


## Installation

```bash
./install.sh
```

This will:
1. Build the Rust binary
2. Install it to `~/.local/bin/aws-auth-monitor`
3. Install the default config to `~/.config/aws-auth-monitor.json`
4. Install and start the background service:
   - **Linux:** systemd user service (`~/.config/systemd/user/aws-auth-monitor.service`)
   - **macOS:** launchd agent (`~/Library/LaunchAgents/com.llmodelcitizen.aws-auth-monitor.plist`)
   - **Neither available** (e.g. a container): a `nohup` background process tracked by a PID file; this does not survive a reboot

To uninstall:
```bash
./install.sh uninstall
```

## Starship Configuration

Add this to your `~/.config/starship.toml`:

```toml
# Disable the built-in AWS module because it shows info even when your session is expired
[aws]
disabled = true

# Custom AWS module that reads from auth-status file
[custom.aws]
command = '''python3 -c "import json; d=json.load(open('$HOME/.aws/auth-status')); print(d.get('display','') if d.get('authenticated') else '')" 2>/dev/null'''
when = "test -f ~/.aws/auth-status"
format = " [$output]($style)"
style = "bold #FF9900"
```

Then add `${custom.aws}` to your `format` string:

```toml
format = """$hostname$directory$git_branch$git_status${custom.aws}$character"""
```

## Service Configuration

Edit `~/.config/aws-auth-monitor.json` to customize the display. The service automatically reloads the config when the file changes.

```json
{
  "prefix": "[aws]",
  "show_prefix": false,
  "show_profile": false,
  "show_region": true,
  "show_account": false,
  "separator": ":",
  "region_aliases": {
    "us-east-1": "use1",
    "us-west-2": "usw2"
  }
}
```

| Option | Default | Description |
|--------|---------|-------------|
| `prefix` | `"[aws]"` | Prefix string when `show_prefix` is true |
| `show_prefix` | `false` | Show prefix before status (e.g., `[aws]`) |
| `show_profile` | `false` | Show AWS profile name |
| `show_region` | `true` | Show AWS region |
| `show_account` | `false` | Show AWS account ID |
| `separator` | `":"` | Separator between fields |
| `region_aliases` | `{}` | Map of region names to shorter aliases |

### Example Outputs

With defaults (`show_region: true` only):
```
us-east-1
```

With region alias configured:
```
use1
```

With `show_prefix: true`, `show_profile: true`, `show_region: true`:
```
[aws] default:us-east-1
```

## Service Management

The service restarts automatically if it exits and starts at login on both platforms. Restarting is rarely needed since the config auto-reloads.

### Linux (systemd)

```bash
# Check status
systemctl --user status aws-auth-monitor

# View logs
journalctl --user -u aws-auth-monitor -f

# Restart
systemctl --user restart aws-auth-monitor
```

### macOS (launchd)

```bash
# Check status
launchctl print gui/$(id -u)/com.llmodelcitizen.aws-auth-monitor

# View logs
tail -f ~/Library/Logs/aws-auth-monitor.log

# Restart
launchctl kickstart -k gui/$(id -u)/com.llmodelcitizen.aws-auth-monitor
```

### Either

```bash
# Run a single check manually
~/.local/bin/aws-auth-monitor --once
```

## Shell Integration

`aws-auth-monitor shell-init bash` prints an `aso` function that toggles AWS SSO login/logout and then restarts the monitor so the prompt updates immediately. Add to your `~/.bashrc` (or `~/.zshrc`):

```bash
eval "$(aws-auth-monitor shell-init bash)"
```

`aso` defaults to `aws sso login --use-device-code`; set `AWS_SSO_LOGIN_METHOD=pkce` to use the localhost-redirect flow instead.

## Files

| Path | Description |
|------|-------------|
| `~/.local/bin/aws-auth-monitor` | The binary |
| `~/.config/aws-auth-monitor.json` | Configuration file |
| `~/.aws/auth-status` | Status file read by Starship |
| `~/.config/systemd/user/aws-auth-monitor.service` | systemd unit file (Linux) |
| `~/Library/LaunchAgents/com.llmodelcitizen.aws-auth-monitor.plist` | launchd agent (macOS) |
| `~/Library/Logs/aws-auth-monitor.log` | Service log (macOS; Linux uses the journal) |

## How It Works

1. The service runs every 60 seconds
2. Calls AWS STS `GetCallerIdentity` to check authentication
3. Writes JSON status to `~/.aws/auth-status`
4. Starship's custom module reads the `display` field from this file
5. If not authenticated, `display` is empty and nothing is shown
