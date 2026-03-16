//! AWS authentication status monitor for Starship prompt.
//!
//! Periodically checks AWS STS identity and writes status to ~/.aws/auth-status
//! for consumption by Starship's custom module.

use aws_config::BehaviorVersion;
use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::env;
use std::path::PathBuf;
use std::sync::mpsc;
use tokio::fs;
use tokio::sync::watch;
use tokio::time::{sleep, Duration};

const CHECK_INTERVAL: Duration = Duration::from_secs(60);

fn print_usage() {
    eprintln!("Usage: aws-auth-monitor [OPTIONS] [COMMAND]");
    eprintln!();
    eprintln!("Options:");
    eprintln!("  --once    Run a single check and exit");
    eprintln!("  --help    Show this help message");
    eprintln!();
    eprintln!("Commands:");
    eprintln!("  shell-init bash    Print shell function for bash (use with eval)");
}

fn print_shell_init_bash() {
    let shell_func = r##"# Toggle AWS SSO login/logout and refresh the auth monitor.
# Usage: aso
aso() {
    local status_file="$HOME/.aws/auth-status"
    if [[ ! -f "$status_file" ]]; then
        echo "Error: $status_file not found"
        echo "Is aws-auth-monitor running?"
        return 1
    fi

    local authenticated
    authenticated=$(python3 -c "import json; print(json.load(open('$status_file')).get('authenticated', False))" 2>/dev/null)

    if [[ "$authenticated" == "True" ]]; then
        echo "Logging out..."
        aws sso logout
    else
        echo "Logging in..."
        local use_device_code=false

        # Check config for explicit override
        local config_file="$HOME/.config/aws-auth-monitor.json"
        if [[ -f "$config_file" ]]; then
            local config_val
            config_val=$(python3 -c "import json; print(json.load(open('$config_file')).get('use_device_code', ''))" 2>/dev/null)
            if [[ "$config_val" == "True" ]]; then
                use_device_code=true
            elif [[ "$config_val" == "False" ]]; then
                use_device_code=false
            fi
        fi

        # If config didn't set it explicitly, detect browser availability
        if [[ "$use_device_code" == "false" ]]; then
            if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" && -z "${BROWSER:-}" ]] || ! command -v xdg-open &>/dev/null; then
                use_device_code=true
            fi
        fi

        if [[ "$use_device_code" == "true" ]]; then
            aws sso login --use-device-code
        else
            aws sso login
        fi
    fi

    # Restart the monitor to pick up the auth change immediately
    if systemctl --user restart aws-auth-monitor 2>/dev/null; then
        :
    elif [[ -f "$HOME/.local/share/aws-auth-monitor/pid" ]]; then
        local pid
        pid=$(cat "$HOME/.local/share/aws-auth-monitor/pid")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
        fi
        nohup "$HOME/.local/bin/aws-auth-monitor" >> "$HOME/.local/share/aws-auth-monitor/output.log" 2>&1 &
        echo $! > "$HOME/.local/share/aws-auth-monitor/pid"
    fi
}"##;
    println!("{}", shell_func);
}

#[derive(Deserialize, Clone)]
#[serde(default)]
struct Config {
    prefix: String,
    show_prefix: bool,
    show_profile: bool,
    show_region: bool,
    show_account: bool,
    separator: String,
    region_aliases: HashMap<String, String>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            show_prefix: false,
            show_profile: false,
            show_region: true,
            show_account: false,
            prefix: "[aws]".to_string(),
            separator: ":".to_string(),
            region_aliases: HashMap::new(),
        }
    }
}

#[derive(Serialize, Default)]
struct AuthStatus {
    authenticated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    profile: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    region: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    account: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    arn: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    user_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    display: String,
}

fn config_file() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| {
            eprintln!("warning: config_dir unavailable, using current directory");
            PathBuf::from(".")
        })
        .join("aws-auth-monitor.json")
}

fn status_file() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| {
            eprintln!("warning: home_dir unavailable, using current directory");
            PathBuf::from(".")
        })
        .join(".aws")
        .join("auth-status")
}

fn load_config_sync() -> Option<Config> {
    let path = config_file();
    match std::fs::read_to_string(&path) {
        Ok(contents) if !contents.is_empty() => serde_json::from_str(&contents).ok(),
        _ => None,
    }
}

async fn load_config() -> Config {
    let path = config_file();
    match fs::read_to_string(&path).await {
        Ok(contents) => serde_json::from_str(&contents).unwrap_or_default(),
        Err(_) => Config::default(),
    }
}

fn format_display(status: &AuthStatus, config: &Config) -> String {
    if !status.authenticated {
        return String::new();
    }

    let mut parts = Vec::new();

    if config.show_prefix {
        parts.push(format!("{} ", config.prefix));
    }

    let mut fields = Vec::new();
    if config.show_profile {
        if let Some(ref profile) = status.profile {
            if !profile.is_empty() {
                fields.push(profile.clone());
            }
        }
    }
    if config.show_region {
        if let Some(ref region) = status.region {
            let display_region = config
                .region_aliases
                .get(region)
                .cloned()
                .unwrap_or_else(|| region.clone());
            fields.push(display_region);
        }
    }
    if config.show_account {
        if let Some(ref account) = status.account {
            fields.push(account.clone());
        }
    }

    if !fields.is_empty() {
        parts.push(fields.join(&config.separator));
    }

    parts.concat()
}

async fn get_auth_status() -> AuthStatus {
    let profile = Some(
        env::var("AWS_PROFILE").unwrap_or_else(|_| "default".to_string()),
    );

    let config = aws_config::defaults(BehaviorVersion::latest()).load().await;

    let region = config.region().map(|r| r.to_string());
    let resolved_profile = profile;

    let sts = aws_sdk_sts::Client::new(&config);

    match sts.get_caller_identity().send().await {
        Ok(identity) => AuthStatus {
            authenticated: true,
            profile: resolved_profile,
            region,
            account: identity.account().map(String::from),
            arn: identity.arn().map(String::from),
            user_id: identity.user_id().map(String::from),
            error: None,
            display: String::new(),
        },
        Err(e) => {
            let error_str = e.to_string();
            let error_lower = error_str.to_lowercase();
            // Check for expected auth failures (don't report as errors)
            // These are normal when not logged in or session expired
            let is_auth_failure = error_lower.contains("no credentials")
                || error_lower.contains("expiredtoken")
                || error_lower.contains("invalidclienttokenid")
                || error_lower.contains("accessdenied")
                || error_lower.contains("sso session")
                || error_lower.contains("sso token")
                || error_lower.contains("credentials provider")
                || error_lower.contains("dispatch failure");

            AuthStatus {
                authenticated: false,
                profile: resolved_profile,
                region,
                account: None,
                arn: None,
                user_id: None,
                error: if is_auth_failure { None } else { Some(error_str) },
                display: String::new(),
            }
        }
    }
}

async fn write_status(status: &AuthStatus) -> std::io::Result<()> {
    let path = status_file();

    // Ensure parent directory exists
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).await?;
    }

    // Write to temp file then rename for atomicity
    let tmp_path = path.with_extension("tmp");
    let json = serde_json::to_string(status)?;
    fs::write(&tmp_path, &json).await?;
    fs::rename(&tmp_path, &path).await?;

    Ok(())
}

fn start_config_watcher(config_tx: watch::Sender<Config>) -> Option<RecommendedWatcher> {
    use std::time::Instant;

    let config_path = config_file();
    let (tx, rx) = mpsc::channel::<Result<Event, notify::Error>>();

    let mut watcher = match RecommendedWatcher::new(
        move |res| {
            let _ = tx.send(res);
        },
        notify::Config::default(),
    ) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("failed to create config watcher: {}", e);
            return None;
        }
    };

    // Watch the config directory (watching the file directly can miss some editors' save patterns)
    let watch_path = config_path.parent().unwrap_or(&config_path);
    if let Err(e) = watcher.watch(watch_path, RecursiveMode::NonRecursive) {
        eprintln!("failed to watch config directory: {}", e);
        return None;
    }

    let config_path_clone = config_path.clone();
    std::thread::spawn(move || {
        let mut last_reload = Instant::now()
            .checked_sub(Duration::from_secs(10))
            .unwrap_or_else(Instant::now);
        let debounce = Duration::from_secs(1);

        for res in rx {
            match res {
                Ok(event) => {
                    // Check if this event affects our config file (or it was renamed/removed and recreated)
                    let affects_config = event.paths.iter().any(|p| {
                        p == &config_path_clone
                            || p.file_name() == config_path_clone.file_name()
                    });

                    if affects_config && last_reload.elapsed() > debounce {
                        if let Some(new_config) = load_config_sync() {
                            last_reload = Instant::now();
                            println!("config reloaded: {}", config_path_clone.display());
                            let _ = config_tx.send(new_config);
                        }
                        // If file missing or parse failed, don't update debounce timer - retry on next event
                    }
                }
                Err(e) => {
                    eprintln!("config watch error: {}", e);
                }
            }
        }
    });

    println!("watching config: {}", config_path.display());
    Some(watcher)
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args: Vec<String> = env::args().collect();
    let once = args.iter().any(|a| a == "--once");
    let help = args.iter().any(|a| a == "--help" || a == "-h");

    if help {
        print_usage();
        return;
    }

    if args.get(1).map(|s| s.as_str()) == Some("shell-init") {
        match args.get(2).map(|s| s.as_str()) {
            Some("bash") => {
                print_shell_init_bash();
                return;
            }
            _ => {
                eprintln!("Usage: aws-auth-monitor shell-init bash");
                std::process::exit(1);
            }
        }
    }

    if once {
        println!("aws-auth-monitor: running single check");
    } else {
        println!(
            "aws-auth-monitor: starting (interval={}s)",
            CHECK_INTERVAL.as_secs()
        );
    }

    // Load initial config
    let initial_config = load_config().await;

    // Set up config watcher (only in daemon mode)
    let (config_tx, mut config_rx) = watch::channel(initial_config);
    let _watcher = if !once {
        start_config_watcher(config_tx)
    } else {
        None
    };

    loop {
        let config = config_rx.borrow_and_update().clone();
        let mut status = get_auth_status().await;
        status.display = format_display(&status, &config);

        if status.authenticated {
            println!(
                "authenticated: account={} region={} profile={}",
                status.account.as_deref().unwrap_or("-"),
                status.region.as_deref().unwrap_or("-"),
                status.profile.as_deref().unwrap_or("-"),
            );
        } else {
            println!("not authenticated");
        }

        if let Some(ref err) = status.error {
            eprintln!("error: {}", err);
        }

        match write_status(&status).await {
            Ok(()) => println!("wrote {}", status_file().display()),
            Err(e) => eprintln!("failed to write status: {}", e),
        }

        if once {
            break;
        }

        // Wait for either the interval or a config change
        tokio::select! {
            _ = sleep(CHECK_INTERVAL) => {}
            _ = config_rx.changed() => {
                println!("config changed, re-checking");
            }
        }
    }
}
