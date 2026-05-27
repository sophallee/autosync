#!/bin/bash

# ==============================================================================
# autosync.sh - A continuous rsync-based synchronization daemon
# ==============================================================================

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
global_properties="$script_dir/global.properties"
global_excludes="$script_dir/autosync.excludes"
configs_dir="$script_dir/configs"
logs_dir="$script_dir/logs"
pid_file="$logs_dir/autosync.pid"
log_file="$logs_dir/autosync.log"

# Ensure essential directories exist
mkdir -p "$logs_dir"
mkdir -p "$configs_dir"

# --- Prevent multiple instances ---
if [[ -f "$pid_file" ]]; then
    pid=$(cat "$pid_file")
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "Error: autosync is already running (PID: $pid)."
        exit 1
    fi
fi
echo $$ > "$pid_file"

# Clean up PID file on exit
trap 'rm -f "$pid_file"; exit' INT TERM EXIT

# --- Helper Functions ---

# Log a message with a specific level (information or error)
log_msg() {
    local level="${1:-information}"
    local msg="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Check if we should log this level
    if [[ "$level" == "information" && "$g_log_level" == "error" ]]; then
        return
    fi

    local formatted_msg="[$timestamp] [${level^^}] $msg"
    
    # Print to stdout for manual runs
    echo "$formatted_msg"
    
    # Write to log file
    echo "$formatted_msg" >> "$log_file"
    
    # Periodic rotation check (every time we log)
    rotate_logs
}

rotate_logs() {
    local max_size=$((g_log_max_size_kb * 1024))
    local backups=$g_log_backups
    
    if [[ -f "$log_file" ]]; then
        local current_size=$(stat -c%s "$log_file")
        if [[ $current_size -ge $max_size ]]; then
            # Rotate backups
            for ((i=backups-1; i>=1; i--)); do
                if [[ -f "$log_file.$i" ]]; then
                    mv "$log_file.$i" "$log_file.$((i+1))"
                fi
            done
            mv "$log_file" "$log_file.1"
            touch "$log_file"
        fi
    fi
}

log_error() {
    local msg="$1"
    local host="${2:-system}"
    log_msg "error" "[$host] $msg"
    
    # Also write to separate error log for backward compatibility if configured
    if [[ -n "$error_log" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$host] ERROR: $msg" >> "$error_log"
    elif [[ -d "$logs_dir" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$host] ERROR: $msg" >> "$logs_dir/autosync.err"
    fi
}

# --- Dependency Checks ---

if ! command -v rsync >/dev/null 2>&1; then
    echo "Error: 'rsync' is not installed on this system."
    echo "  Please install it using your package manager:"
    echo "    - Debian/Ubuntu: sudo apt install rsync"
    echo "    - RedHat/CentOS/Fedora: sudo dnf install rsync (or yum)"
    echo "    - macOS: brew install rsync"
    echo "  Note: 'rsync' must be installed on BOTH the local and remote machines."
    exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
    echo "Error: 'ssh' is not installed on this system."
    echo "  Please install an SSH client to use this script."
    exit 1
fi

# --- Initialization & Checks ---

missing_global=0

check_config_exists() {
    local target="$1"
    local template="$2"
    if [[ ! -f "$target" ]]; then
        echo "Advice: Global configuration file '$(basename "$target")' is missing."
        if [[ -f "$template" ]]; then
            echo "  Please copy it from the template: cp $template $target"
        fi
        missing_global=1
    fi
}

# Check for global config files
check_config_exists "$global_properties" "$script_dir/global.properties.template"
check_config_exists "$global_excludes" "$script_dir/autosync.excludes.template"

if [[ $missing_global -eq 1 ]]; then
    echo "Please set up the missing global configuration files before continuing."
    exit 1
fi

# Load global properties initially to set logging defaults
# shellcheck source=/dev/null
source "$global_properties"
g_log_level="${log_level:-error}"
g_log_max_size_kb="${log_max_size_kb:-1024}"
g_log_backups="${log_backups:-5}"

# --- Connection Helper Functions ---

# Checks if rsync is available on a remote host
# Returns: 0 = found, 1 = not found, 2 = SSH error
check_remote_rsync() {
    local user="$1"
    local ip="$2"
    local port="$3"
    local key="$4"
    
    local remote_login=""
    [[ -n "$user" ]] && remote_login="${user}@"
    
    local ssh_args=("-o" "BatchMode=yes" "-o" "ConnectTimeout=10")
    [[ -n "$port" ]] && ssh_args+=("-p" "$port")
    [[ -n "$key" ]] && ssh_args+=("-i" "$key")
    
    ssh "${ssh_args[@]}" "${remote_login}${ip}" "command -v rsync" >/dev/null 2>&1
    local exit_status=$?
    
    if [[ $exit_status -eq 0 ]]; then
        return 0
    elif [[ $exit_status -eq 1 ]]; then
        return 1
    else
        return 2
    fi
}

# Resolves host connection details from an alias or direct string
# Output format: user,ip,port,key
resolve_host() {
    local input="$1"
    
    # Priority 1: Check if input is a defined host variable (host_XXX="user@ip:port:key")
    local var_name="host_${input}"
    local var_value="${!var_name}"
    
    if [[ -n "$var_value" ]]; then
        IFS=":" read -ra parts <<< "$var_value"
        local user_ip="${parts[0]}"
        local port="${parts[1]}"
        local key="${parts[2]}"
        
        if [[ "$user_ip" == *"@"* ]]; then
            IFS="@" read -ra user_ip_parts <<< "$user_ip"
            echo "${user_ip_parts[0]},${user_ip_parts[1]},$port,$key"
        else
            echo ",$user_ip,$port,$key"
        fi
        return
    fi
    
    # Priority 2: Check if input is a direct connection string (user@ip[:port[:key]])
    if [[ "$input" == *"@"* ]]; then
        IFS=":" read -ra parts <<< "$input"
        local user_ip="${parts[0]}"
        local port="${parts[1]}"
        local key="${parts[2]}"
        
        IFS="@" read -ra user_ip_parts <<< "$user_ip"
        echo "${user_ip_parts[0]},${user_ip_parts[1]},$port,$key"
        return
    fi

    # Priority 3: Treat input as a hostname/IP (supports .ssh/config aliases)
    if [[ -n "$input" ]]; then
        echo ",$input,,"
        return
    fi

    # Priority 4: Fallback to host-level or global defaults
    echo "$remote_user,$remote_ip,$remote_port,$ssh_key"
}

# --- Main Logic ---

log_msg "information" "Starting autosync daemon..."

# Keep track of verified hosts to avoid redundant SSH checks
verified_hosts_cache=""

while true; do
    # Clear cache for the new iteration
    verified_hosts_cache=" "

    # Reload global properties to pick up runtime changes
    # shellcheck source=/dev/null
    source "$global_properties"
    g_log_level="${log_level:-error}"
    g_log_max_size_kb="${log_max_size_kb:-1024}"
    g_log_backups="${log_backups:-5}"

    # Set global defaults if not defined
    check_interval="${check_interval:-60}"
    max_folders="${max_folders:-20}"
    g_ssh_key="${ssh_key}"
    g_remote_ip="${remote_ip}"
    g_remote_port="${remote_port}"
    g_remote_user="${remote_user}"
    g_remote_path="${remote_path}"

    # Find all host property files in the configs directory
    shopt -s nullglob
    host_files=("$configs_dir"/*.properties)
    shopt -u nullglob

    if [[ ${#host_files[@]} -eq 0 && -z "$g_remote_ip" ]]; then
        log_msg "information" "Advice: No host configuration files found in '$configs_dir' and no global 'remote_ip' is defined."
        sleep 30
        continue
    fi

    for host_file in "${host_files[@]}"; do
        # Reset host-specific variables
        description=""
        ssh_key="$g_ssh_key"
        remote_ip="$g_remote_ip"
        remote_port="$g_remote_port"
        remote_user="$g_remote_user"
        remote_path="$g_remote_path"
        
        # Clear previous job definitions
        for i in $(seq 1 "$max_folders"); do unset "synced_folder$i"; done

        # Load host config
        # shellcheck source=/dev/null
        source "$host_file"
        
        host_filename=$(basename "$host_file" .properties)
        host_label="${description:-$host_filename}"

        # Automatic host-specific exclude file detection
        host_default_exclude=""
        if [[ -f "$configs_dir/${host_filename}.exclude" ]]; then
            host_default_exclude="$configs_dir/${host_filename}.exclude"
        fi

        log_msg "information" "--- Processing Host: $host_label ---"

        # Check if we have enough info to connect
        if [[ -z "$remote_ip" ]]; then
            log_msg "information" "  Advice: SSH details (remote_ip) are missing for this host and no global default exists."
            continue
        fi

        for i in $(seq 1 "$max_folders"); do
            synced_var="synced_folder${i}"
            value="${!synced_var}"
            [[ -z "$value" ]] && break

            # Parse fields: direction,host_alias,local_path,remote_path,exclude_file
            IFS="," read -ra fields <<< "$value"
            
            if [[ ${#fields[@]} -ge 3 ]]; then
                direction="${fields[0]}"
                host_alias="${fields[1]}"
                local_path="${fields[2]}"
                remote_subpath="${fields[3]:-$remote_path}"
                exclude_file="${fields[4]}"
            else
                # Legacy/Simplified format: local_path,remote_path,exclude_file (assumes pull)
                direction="pull"
                host_alias=""
                local_path="${fields[0]}"
                remote_subpath="${fields[1]:-$remote_path}"
                exclude_file="${fields[2]}"
            fi

            # Resolve connection parameters
            IFS="," read -ra host_info <<< "$(resolve_host "$host_alias")"
            user="${host_info[0]}"
            ip="${host_info[1]}"
            port="${host_info[2]}"
            key="${host_info[3]}"

            if [[ -z "$ip" ]]; then
                log_msg "information" "  [Job $i] Skip: No target IP or Hostname defined for this job."
                continue
            fi

            # --- Remote Pre-Check (Once per host per iteration) ---
            host_identifier="${user}@${ip}:${port}"
            if [[ "$verified_hosts_cache" != *" $host_identifier "* ]]; then
                log_msg "information" "  [Job $i] Verifying remote rsync on $ip..."
                check_remote_rsync "$user" "$ip" "$port" "$key"
                check_status=$?
                
                if [[ $check_status -eq 0 ]]; then
                    verified_hosts_cache+="$host_identifier "
                elif [[ $check_status -eq 1 ]]; then
                    log_msg "error" "  [Job $i] Error: 'rsync' is NOT installed on the remote host ($ip)."
                    log_error "rsync missing on remote host $ip" "$host_filename"
                    continue
                else
                    log_msg "information" "  [Job $i] Warning: Could not verify remote rsync (SSH connection failed)."
                fi
            fi

            # Construct rsync arguments
            rsync_args=("-avz" "--delete")
            
            # SSH configuration (cater for .ssh/config by omitting empty values)
            ssh_cmd="ssh"
            [[ -n "$port" ]] && ssh_cmd="$ssh_cmd -p $port"
            [[ -n "$key" ]] && ssh_cmd="$ssh_cmd -i $key"
            rsync_args+=("-e" "$ssh_cmd")

            # Exclusion logic
            # 1. Global excludes
            [[ -f "$global_excludes" ]] && rsync_args+=("--exclude-from=$global_excludes")
            # 2. Host-specific default exclude (e.g., srv2.exclude)
            [[ -n "$host_default_exclude" ]] && rsync_args+=("--exclude-from=$host_default_exclude")
            # 3. Job-specific exclude
            if [[ -n "$exclude_file" ]]; then
                if [[ -f "$configs_dir/$exclude_file" ]]; then
                    rsync_args+=("--exclude-from=$configs_dir/$exclude_file")
                elif [[ -f "$exclude_file" ]]; then
                    rsync_args+=("--exclude-from=$exclude_file")
                fi
            fi

            # Set source and destination based on direction
            remote_login=""
            [[ -n "$user" ]] && remote_login="${user}@"
            
            if [[ "$direction" == "push" ]]; then
                src="$local_path"
                dest="${remote_login}${ip}:${remote_subpath}"
            else
                src="${remote_login}${ip}:${remote_subpath}"
                dest="$local_path"
            fi

            log_msg "information" "  [Job $i] Syncing ($direction): $src -> $dest"
            
            # Execute rsync
            if rsync "${rsync_args[@]}" "$src" "$dest"; then
                : # Success
            else
                log_error "rsync failed for $src -> $dest" "$host_filename"
                log_msg "error" "  [Job $i] Error: rsync failed. See logs/autosync.log for details."
            fi
        done
    done

    log_msg "information" "Waiting $check_interval seconds..."
    sleep "$check_interval"
done
