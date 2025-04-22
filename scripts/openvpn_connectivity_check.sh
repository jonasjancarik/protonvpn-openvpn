#!/bin/bash

# Script to check connectivity and optional SSSD domain status.
# Kills openvpn if connectivity check fails or SSSD domain is offline.
# Intended to be run periodically (e.g., by systemd timer).

# Configuration from environment variables
CONNECTIVITY_CHECK_DOMAIN="$CONNECTIVITY_CHECK_DOMAIN" # General domain to check
SSSD_DOMAIN="$SSSD_DOMAIN"                           # Specific SSSD domain (optional)
LOG_FILE="/var/log/openvpn_connectivity_check.log"   # Log file

# --- Helper Functions ---

# Function to log messages
log_message() {
    # Ensure log file exists and is writable (best effort)
    touch "$LOG_FILE" &> /dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to check general domain connectivity (DNS + optional ping)
check_connectivity() {
    local domain="$1"
    local ip_address

    # DNS resolution
    if command -v nslookup &> /dev/null; then
        ip_address=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / { print $2 }' | head -n 1)
    elif command -v host &> /dev/null; then
        ip_address=$(host "$domain" 2>/dev/null | awk '/ has address | has IPv6 address / { print $NF }' | head -n 1)
    else
        log_message "Warning: Neither nslookup nor host found. Cannot check DNS for $domain. Assuming reachable."
        return 0 # Assume reachable if tools missing
    fi

    if [ -z "$ip_address" ]; then
        log_message "Error: Could not resolve IP address for $domain."
        return 1 # DNS failed -> Unreachable
    fi
    log_message "Connectivity Check: Successfully resolved $domain to $ip_address."

    # Optional Ping check
    if command -v ping &> /dev/null; then
        # Sending 1 packet (-c 1), timeout after 2 seconds (-W 2)
        if ping -c 1 -W 2 "$ip_address" > /dev/null 2>&1; then
            log_message "Connectivity Check: Successfully pinged $ip_address for $domain."
            return 0 # Ping successful -> Reachable
        else
            log_message "Connectivity Check: Warning: Failed to ping $ip_address for domain $domain. Treating as reachable based on DNS."
            # Change to 'return 1' if ping failure should mean unreachable
            return 0
        fi
    else
        log_message "Connectivity Check: Warning: ping command not found. Skipping ping test for $domain."
        return 0 # Assume reachable based on DNS
    fi
}

# Function to check SSSD domain status
check_sssd_status() {
    local domain="$1"

    if ! command -v sssctl &> /dev/null; then
        log_message "SSSD Check: Warning: sssctl command not found. Cannot check SSSD status for $domain. Assuming online."
        # Assume online if tool is missing
        return 0
    fi

    # Check if domain status is reported as Offline
    # Redirect stderr to null to suppress errors if domain doesn't exist in sssd.conf
    if sssctl domain-status "$domain" 2>/dev/null | grep -q 'Online status: Offline'; then
        log_message "SSSD Check: SSSD domain $domain status is Offline."
        return 1 # SSSD is Offline
    else
        # This covers Online status or cases where the domain isn't actively managed/found by sssctl
        log_message "SSSD Check: SSSD domain $domain status is Online or not applicable."
        return 0 # SSSD is Online or effectively not 'Offline'
    fi
}

# --- Main Script Logic ---

# Exit if no domains are specified to check
if [ -z "$CONNECTIVITY_CHECK_DOMAIN" ] && [ -z "$SSSD_DOMAIN" ]; then
    echo "Error: Neither CONNECTIVITY_CHECK_DOMAIN nor SSSD_DOMAIN environment variables are set. Exiting."
    # Avoid logging this as an error state if it's just configuration
    exit 1
fi

connectivity_ok=true
sssd_ok=true
trigger_kill=false

# Perform connectivity check if domain is specified
if [ -n "$CONNECTIVITY_CHECK_DOMAIN" ]; then
    if ! check_connectivity "$CONNECTIVITY_CHECK_DOMAIN"; then
        log_message "Result: Connectivity check FAILED for $CONNECTIVITY_CHECK_DOMAIN."
        connectivity_ok=false
        trigger_kill=true
    else
        log_message "Result: Connectivity check PASSED for $CONNECTIVITY_CHECK_DOMAIN."
    fi
fi

# Perform SSSD check if domain is specified
if [ -n "$SSSD_DOMAIN" ]; then
    if ! check_sssd_status "$SSSD_DOMAIN"; then
        log_message "Result: SSSD status check FAILED for $SSSD_DOMAIN (Offline)."
        sssd_ok=false
        trigger_kill=true
    else
         log_message "Result: SSSD status check PASSED for $SSSD_DOMAIN (Online/Not Offline)."
    fi
fi

# Kill OpenVPN if either check failed
if $trigger_kill; then
    log_message "Action: One or more checks failed. Checking for OpenVPN process..."
    if pgrep -f "^openvpn" > /dev/null; then
        log_message "Action: OpenVPN process found. Killing OpenVPN..."
        # Attempt to kill openvpn gracefully first, then forcefully
        # Use sudo only if not already running as root
        if [ "$(id -u)" -ne 0 ]; then
            sudo pkill -SIGTERM -f "^openvpn" || true
            sleep 2 # Give it a moment to terminate
            sudo pkill -SIGKILL -f "^openvpn" || true
        else
            pkill -SIGTERM -f "^openvpn" || true
            sleep 2 # Give it a moment to terminate
            pkill -SIGKILL -f "^openvpn" || true
        fi
        log_message "Action: Sent kill signals to OpenVPN."
    else
        log_message "Action: OpenVPN process not found. No kill action needed."
    fi
else
    log_message "Result: All checks passed. No action needed."
fi

exit 0 