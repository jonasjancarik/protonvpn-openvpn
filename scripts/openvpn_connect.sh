#!/bin/bash
#
# Picks the newest .ovpn file from ~/Downloads,
# Reads persistent configuration from ~/.openvpn/config.env (if it exists),
# Injects routes for domains specified in $NO_VPN_DOMAINS (comma-separated) to bypass the VPN,
# Optionally skips SSSD checks if --no-sssd flag is given.
# then starts openvpn in daemon mode,
# and waits/polls the log file to see if it connects successfully.

# --- Argument Parsing ---
SKIP_SSSD=false
# Process flags first
TEMP_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-sssd)
      SKIP_SSSD=true
      shift # past argument
      ;;
    -*|--*)
      echo "Unknown option $1" >&2
      exit 1
      ;;
    *)
      # Save positional arguments if any are needed later (currently none)
      # TEMP_ARGS+=("$1") 
      shift # past argument
      ;;
  esac
done
# Restore positional arguments if needed (currently none)
# set -- "${TEMP_ARGS[@]}" 

set -x  # Enable debug output (after arg parsing)

# Source persistent configuration if it exists
CONFIG_ENV_FILE="$HOME/.openvpn/config.env"
if [[ -f "$CONFIG_ENV_FILE" ]]; then
    echo "Loading configuration from $CONFIG_ENV_FILE"
    # Source the file - variables defined in it are now available here
    # Use . instead of source for better portability
    . "$CONFIG_ENV_FILE"
fi

CREDENTIALS_FILE="$HOME/.openvpn/credentials.txt"
LATEST_OVPN="$(ls -t "$HOME"/Downloads/*.ovpn 2>/dev/null | head -n 1)"

if [[ -z "$LATEST_OVPN" ]]; then
  notify-send "OpenVPN" "No .ovpn files found in $HOME/Downloads."
  exit 1
fi

# We'll keep a temporary copy to avoid modifying the user's .ovpn file
TEMP_OVPN="/tmp/openvpn_temp_$(date +%s).ovpn"
cp "$LATEST_OVPN" "$TEMP_OVPN"

# Function to resolve all A record IPs for a domain
get_domain_ips() {
  local domain=$1
  local ips=()
  if command -v dig &>/dev/null; then
    # Use dig if available
    ips=($(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true))
  elif command -v host &>/dev/null; then
    # Fallback to host
    ips=($(host -t A "$domain" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true))
  elif command -v nslookup &>/dev/null; then
    # Fallback to nslookup (parsing might be less robust)
    ips=($(nslookup "$domain" | awk '/^Address: / {print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true))
  else
    echo "Warning: dig, host, and nslookup not found. Cannot resolve IPs for $domain." >&2
  fi
  # Return unique IPs
  if [[ ${#ips[@]} -gt 0 ]]; then
    printf "%s\n" "${ips[@]}" | sort -u
  fi
}

# Function to resolve a single hostname to its primary IP
get_hostname_ip() {
  local hostname=$1
  local ip=""
  if command -v host &>/dev/null; then
    ip=$(host "$hostname" 2>/dev/null | awk '/has address/ {print $4; exit}')
  elif command -v nslookup &>/dev/null; then
    ip=$(nslookup "$hostname" 2>/dev/null | awk '/^Address: / {print $2; exit}')
  else
      echo "Warning: host and nslookup not found. Cannot resolve hostname $hostname." >&2
  fi
  echo "$ip"
}

# If NO_VPN_DOMAINS is set, resolve IPs and inject routes
if [[ -n "$NO_VPN_DOMAINS" ]]; then
  echo "NO_VPN_DOMAINS set to '$NO_VPN_DOMAINS'. Resolving IPs and adding routes..."
  # Save original IFS and set it to comma for splitting
  ORIGINAL_IFS=$IFS
  IFS=',' 
  read -ra DOMAINS_TO_BYPASS <<< "$NO_VPN_DOMAINS"
  # Restore original IFS
  IFS=$ORIGINAL_IFS

  for domain in "${DOMAINS_TO_BYPASS[@]}"; do
    # Trim whitespace
    domain=$(echo "$domain" | xargs)
    if [[ -z "$domain" ]]; then
      continue
    fi
    echo "Processing domain: $domain"
    DOMAIN_IPS=()
    # Read resolved IPs into an array, handling potential errors
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && DOMAIN_IPS+=("$ip")
    done < <(get_domain_ips "$domain")

    if [[ ${#DOMAIN_IPS[@]} -eq 0 ]]; then
        echo "Warning: Could not resolve any IPs for domain '$domain'. Skipping route addition." >&2
        continue
    fi

    for IP in "${DOMAIN_IPS[@]}"; do
      if [[ -n "$IP" ]]; then
        echo "Adding route for $domain ($IP) via net_gateway..."
        # Append route to the temporary config file
        echo "route $IP 255.255.255.255 net_gateway" >> "$TEMP_OVPN"
      fi
    done
  done
fi

# --- SSSD Domain Controller Route Injection ---
if [[ "$SKIP_SSSD" == "false" ]]; then
  echo "Checking for SSSD configuration..."
  SSSD_DOMAINS=()
  while IFS= read -r line; do
      [[ -n "$line" ]] && SSSD_DOMAINS+=("$line")
  done < <(sudo sssctl domain-list 2>/dev/null)

  NUM_SSSD_DOMAINS=${#SSSD_DOMAINS[@]}

  if [[ $NUM_SSSD_DOMAINS -gt 0 ]]; then
    echo "Found $NUM_SSSD_DOMAINS SSSD domain(s): ${SSSD_DOMAINS[*]}"
    # Process each found domain
    for DETECTED_SSSD_DOMAIN in "${SSSD_DOMAINS[@]}"; do
      echo "Processing SSSD domain: '$DETECTED_SSSD_DOMAIN'. Discovering domain controllers and adding routes..."
      # Attempt to get DC info. Redirect stderr to /dev/null to suppress errors if domain is offline.
      DC_INFO=$(sssctl domain-status "$DETECTED_SSSD_DOMAIN" 2>/dev/null)
      if [[ -z "$DC_INFO" ]]; then
          echo "Warning: Could not get domain status for '$DETECTED_SSSD_DOMAIN'. SSSD might be offline or domain not configured." >&2
      else
          # Parse the output for server names/IPs
          DC_LINES=$(echo "$DC_INFO" | awk '/Discovered .* Domain Controller servers:/ {flag=1; next} flag && /^$/ {flag=0} flag')
          declare -A SSSD_IPS # Use associative array to store unique IPs for *this* domain
          while IFS= read -r line; do
              [[ -z "$line" ]] && continue
              line=$(echo "$line" | xargs)
              for word in $line; do
                  local current_ip=""
                  if [[ "$word" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                      current_ip="$word"
                  else
                      resolved_ip=$(get_hostname_ip "$word")
                      if [[ -n "$resolved_ip" ]]; then
                          current_ip="$resolved_ip"
                      else
                          echo "Warning: Could not resolve SSSD DC hostname '$word' for domain '$DETECTED_SSSD_DOMAIN'. Skipping." >&2
                      fi
                  fi
                  if [[ -n "$current_ip" ]]; then
                      # Add IP to array (key is IP, value is 1, ensures uniqueness)
                      SSSD_IPS["$current_ip"]=1
                  fi
              done
          done <<< "$DC_LINES"

          # Add routes for the unique IPs found for this domain
          added_route_count=0
          for IP in "${!SSSD_IPS[@]}"; do
              echo "Adding SSSD route for $IP (Domain: $DETECTED_SSSD_DOMAIN) via net_gateway..."
              echo "route $IP 255.255.255.255 net_gateway" >> "$TEMP_OVPN"
              ((added_route_count++))
          done

          if [[ $added_route_count -eq 0 ]]; then
              echo "Warning: No SSSD Domain Controller IPs found or resolved for '$DETECTED_SSSD_DOMAIN'." >&2
          fi
          # Clear the array for the next domain
          unset SSSD_IPS 
      fi
    done # End loop through domains
  elif [[ $NUM_SSSD_DOMAINS -eq 0 ]]; then
      echo "No SSSD domains found. Skipping SSSD DC route injection."
  # The -gt 1 case is now handled by the loop, so no specific message needed here
  fi
else
    echo "Skipping SSSD check due to --no-sssd flag."
fi
# --- End of SSSD Block ---

LOG_FILE="/tmp/openvpn_connect_$(id -u).log"
PID_FILE="/tmp/openvpn_$(id -u).pid"
INTERFACE="proton$(id -u)"

# Clean up any existing files
sudo rm -f "$LOG_FILE" "$PID_FILE"

# Create log file with proper permissions using sudo
sudo touch "$LOG_FILE"
sudo chmod 644 "$LOG_FILE"

# Kill any existing OpenVPN processes
sudo pkill -f '^openvpn' || true
sleep 1

# Overwrite the previous log each time (use --log-append if you want to accumulate)
sudo openvpn --verb 4 --daemon \
             --config "$TEMP_OVPN" \
             --auth-user-pass "$CREDENTIALS_FILE" \
             --dev "$INTERFACE" \
             --dev-type tun \
             --down /usr/local/bin/openvpn-down.sh \
             --log "$LOG_FILE" \
             --writepid "$PID_FILE"

# Send initial notification with transient hint
notify-send -h int:transient:1 "OpenVPN" "Connecting using $(basename "$LATEST_OVPN")..."

# Poll the log file for ~30 seconds
SUCCESS_MSG="Initialization Sequence Completed"
FAIL_PATTERNS="AUTH_FAILED|TLS_ERROR"

for ((i=1; i<=10; i++)); do
  sleep 3

  # Check for success first
  if grep -q "$SUCCESS_MSG" "$LOG_FILE" 2>/dev/null; then
    notify-send "OpenVPN" "VPN connection established successfully."
    exit 0
  fi

  # Then check for known failure patterns
  if grep -Eq "$FAIL_PATTERNS" "$LOG_FILE" 2>/dev/null; then
    notify-send "OpenVPN" "VPN connection failed. Check $LOG_FILE for details."
    if [[ -f "$PID_FILE" ]]; then
      # Attempt to kill the process if it's still running despite the error log
      sudo kill "$(cat "$PID_FILE")" 2>/dev/null || true
    fi
    exit 1
  fi

  # Finally, check if the process died unexpectedly
  if ! [ -f "$PID_FILE" ] || ! [ -s "$PID_FILE" ] || ! pgrep -F "$PID_FILE" >/dev/null 2>&1; then
    notify-send "OpenVPN" "VPN process exited prematurely. Check $LOG_FILE."
    # Check log one last time for success/fail patterns that might have appeared just before exit
    if grep -q "$SUCCESS_MSG" "$LOG_FILE" 2>/dev/null; then
        notify-send "OpenVPN" "VPN connection established successfully (despite process exit)."
        exit 0
    elif grep -Eq "$FAIL_PATTERNS" "$LOG_FILE" 2>/dev/null; then
        notify-send "OpenVPN" "VPN connection failed (process exited). Check $LOG_FILE for details."
        exit 1
    else 
        # Truly premature exit without specific log messages
        exit 1 
    fi
  fi
done

# If we never saw success or an explicit fail message, consider it a timeout
notify-send "OpenVPN" "VPN connection timed out. Check $LOG_FILE."
if [[ -f "$PID_FILE" ]]; then
  sudo kill "$(cat "$PID_FILE")" 2>/dev/null
fi
exit 1 