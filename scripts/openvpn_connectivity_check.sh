#!/bin/bash

# Script to check if a specific domain is reachable.
# If the domain is not reachable, it kills any running openvpn process.
# This is intended to be run as a systemd service.

# Domain to check is passed via environment variable
DOMAIN_TO_CHECK="$CONNECTIVITY_CHECK_DOMAIN"

if [ -z "$DOMAIN_TO_CHECK" ]; then
    echo "Error: CONNECTIVITY_CHECK_DOMAIN environment variable is not set. Exiting."
    exit 1
fi

# Function to check domain connectivity using nslookup or host
check_domain() {
    if command -v nslookup &> /dev/null; then
        nslookup "$1" > /dev/null 2>&1
    elif command -v host &> /dev/null; then
        host "$1" > /dev/null 2>&1
    else
        echo "Warning: Neither nslookup nor host command found. Cannot check domain connectivity."
        return 0 # Assume reachable if tools are missing
    fi
    return $?
}

# Check if the domain is reachable
if ! check_domain "$DOMAIN_TO_CHECK"; then
    echo "Domain $DOMAIN_TO_CHECK is not reachable."
    # Check if openvpn is running
    if pgrep -f "^openvpn" > /dev/null; then
        echo "OpenVPN process found. Killing OpenVPN..."
        # Attempt to kill openvpn gracefully first, then forcefully
        sudo pkill -SIGTERM -f "^openvpn" || true
        sleep 2 # Give it a moment to terminate
        sudo pkill -SIGKILL -f "^openvpn" || true
    else
        echo "OpenVPN is not running."
    fi
else
    echo "Domain $DOMAIN_TO_CHECK is reachable."
fi 