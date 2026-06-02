# autosync

A daemon script that continuously pulls or pushes files between a remote server and local directories using `rsync` over SSH.

## Features

- **Continuous Sync**: Loops indefinitely based on a configurable interval.
- **Modular Configuration**: Support for global defaults and per-host property files.
- **Dependency Checks**: Verifies `rsync` and `ssh` are installed locally and on the remote host.
- **Smart Excludes**: Supports global, host-specific, and job-specific exclude files.
- **Single Instance Protection**: Uses a PID file to prevent multiple instances from running.
- **SSH Config Friendly**: Works seamlessly with `~/.ssh/config` aliases.

## Setup

1. **Initial Run**: Run the script to check for missing dependencies and global files:
   ```bash
   ./autosync.sh
   ```
2. **Configuration**:
   - Copy `global.properties.template` to `global.properties` and edit your defaults.
   - Copy `autosync.excludes.template` to `autosync.excludes` for global rsync filters.
3. **Add Hosts**: Place `.properties` files in the `configs/` directory.

## Running as a Systemd User Service (Recommended)

You can run `autosync` as a background service managed by `systemd` for your specific user. This ensures it starts automatically on login and restarts if it fails.

1. **Install the service**:
   ```bash
   ./autosync.sh --setup-service
   ```
2. **Start the service**:
   ```bash
   systemctl --user start autosync.service
   ```
3. **Management Commands**:
   - **View Status**: `systemctl --user status autosync.service`
   - **View Logs**: `journalctl --user -u autosync.service -f`
   - **Stop Service**: `systemctl --user stop autosync.service`

## Running as a Daemon (Crontab)
...
## Modular Config Structure

### 1. Global Properties (`global.properties`)
Set global defaults for connections and logging:
- `log_level`: Set to `error` (default) or `information` for more detailed logs.
- `log_max_size_kb`: Max size of the log file before rotation.
- `log_backups`: Number of rotated backups to keep.

### 2. Host Properties (`configs/*.properties`)
Define host-specific settings or sync jobs. Every `.properties` file in `configs/` is loaded.
```bash
description="Production Web Server"
remote_ip="web01"
remote_user="deploy"

# Sync jobs: "direction,host_alias,local_path,remote_path,exclude_file,options"
synced_folder1="pull,,/var/www/html,/var/www/html,,delete"
```

### 2. Host-Specific Excludes
If a file named `hostname.exclude` exists in `configs/` (where `hostname` matches the `.properties` filename), it is automatically applied to all jobs for that host.

### 3. SSH Configuration
The script supports `.ssh/config`. If you leave `ssh_key` and `remote_port` empty, it will use your system defaults for the given `remote_ip`.

## Requirements

- **Local**: `rsync`, `ssh`
- **Remote**: `rsync` must be installed on the target machine.

## Logs & Management

- **Logs**: `logs/autosync.log` (stdout) and `logs/autosync.err` (rsync errors).
- **PID File**: `logs/autosync.pid` ensures only one instance runs.
- **Stop the daemon**: `kill $(cat logs/autosync.pid)`
