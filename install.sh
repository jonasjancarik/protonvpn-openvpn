#!/bin/bash

set -e

# Determine the effective user's home directory, even when run with sudo
if [[ -n "$SUDO_USER" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
elif [[ -n "$USER" ]]; then
    USER_HOME=$(getent passwd "$USER" | cut -d: -f6)
else
    USER_HOME=$HOME # Fallback, might be /root under sudo
fi

# Ensure USER_HOME is set
if [[ -z "$USER_HOME" ]]; then
    echo -e "${RED}Error: Could not determine the user's home directory.${ENDCOLOR}" >&2
    exit 1
fi
echo "Effective user home directory: $USER_HOME"

###################################
# ----------- Colors ------------ #
###################################
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
ENDCOLOR="\e[0m"

###################################
# ---- Process Args ------------- #
###################################
FORCE_FLAG=false
CONNECTIVITY_CHECK_DOMAIN=""
NO_VPN_DOMAINS_ARG=""

# Use getopt for better argument parsing
TEMP=$(getopt -o '' --long force,check-domain:,no-vpn-domains: -n 'install.sh' -- "$@")
if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi

# Note the quotes around "$TEMP": they are essential!
eval set -- "$TEMP"

while true; do
  case "$1" in
    --force )          FORCE_FLAG=true; shift ;;
    --check-domain )   CONNECTIVITY_CHECK_DOMAIN="$2"; shift 2 ;;
    --no-vpn-domains ) NO_VPN_DOMAINS_ARG="$2"; shift 2 ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done


if [[ "$FORCE_FLAG" == "true" ]]; then
  echo -e "${YELLOW}Force flag is enabled. Existing files will be overwritten.${ENDCOLOR}"
fi
if [[ -n "$CONNECTIVITY_CHECK_DOMAIN" ]]; then
    echo -e "${YELLOW}Connectivity check enabled for domain: $CONNECTIVITY_CHECK_DOMAIN${ENDCOLOR}"
fi
if [[ -n "$NO_VPN_DOMAINS_ARG" ]]; then
    echo -e "${YELLOW}Domains to bypass VPN set to: $NO_VPN_DOMAINS_ARG${ENDCOLOR}"
fi

# Array to hold paths of files created by this run (to aid cleanup if something fails)
# Config files are generally not added here as they contain user settings
CREATED_FILES=()
CREATED_CONNECTIVITY_SERVICE=false
CREATED_INDICATOR_CONFIG=false

###################################
# ---------- Cleanup  ------------ #
###################################
function cleanup {
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Something went wrong...${ENDCOLOR}"
    echo "Performing cleanup..."
    # Remove every file we created.
    for file in "${CREATED_FILES[@]}"; do
      if [[ -f "$file" ]]; then
        echo "Removing $file"
        # Use sudo for system files
        if [[ "$file" == /usr/local/bin/* || "$file" == /etc/systemd/system/* ]]; then
          sudo rm -f "$file"
        else
          rm -f "$file"
        fi
      fi
    done
    # If we created the domain connectivity check service, stop and disable it.
    if $CREATED_CONNECTIVITY_SERVICE; then
      sudo systemctl stop openvpn_connectivity_check.service > /dev/null 2>&1 || true
      sudo systemctl disable openvpn_connectivity_check.service > /dev/null 2>&1 || true
      sudo rm -f /etc/systemd/system/openvpn_connectivity_check.service
    fi
    # Optionally, remove indicator config if it was created.
    if $CREATED_INDICATOR_CONFIG; then
      rm -f "$HOME/.indicator-sysmonitor.json"
    fi
    # We don't typically remove the config file on cleanup unless explicitly asked
  fi
}

trap cleanup EXIT

###################################
# ------ Script Banner ---------- #
###################################
echo "================================================="
echo "=                                               ="
echo "=      OpenVPN Setup Script (v0.2b)             ="
echo "=                                               ="
echo "================================================="
echo ""
echo -e "${YELLOW}IMPORTANT:${ENDCOLOR} You will need your special OpenVPN username and password from:"
echo "  https://account.protonvpn.com/account-password#openvpn"
echo "They are NOT the same as your normal ProtonVPN login credentials!"
echo ""

###################################
# --- Install Prerequisites ----- #
###################################
echo "Installing/checking dependencies..."

if ! command -v openvpn &>/dev/null; then
    echo "Installing openvpn..."
    sudo apt-get update -y > /dev/null 2>&1 || true
    sudo apt-get install -y openvpn > /dev/null 2>&1 || true
fi

if ! command -v dialog &>/dev/null; then
    echo "Installing dialog..."
    sudo apt-get update -y > /dev/null 2>&1 || true
    sudo apt-get install -y dialog > /dev/null 2>&1 || true
fi

if ! command -v nslookup &>/dev/null && ! command -v host &>/dev/null; then
    echo "Installing dnsutils..."
    sudo apt-get update -y > /dev/null 2>&1 || true
    sudo apt-get install -y dnsutils > /dev/null 2>&1 || true
fi

###################################
# - Prompt for OpenVPN Credentials #
###################################
CREDENTIALS_FILE="$USER_HOME/.openvpn/credentials.txt"

if [[ ! -s "$CREDENTIALS_FILE" ]]; then
    echo "No OpenVPN credentials found at $CREDENTIALS_FILE."
    echo "Please provide your special OpenVPN username and password from ProtonVPN."
    echo "They are available here: https://account.protonvpn.com/account-password#openvpn"
    echo -e "${YELLOW}(Note: Your input will be visible as you type.)${ENDCOLOR}"
    echo ""
    read -p "Enter your OpenVPN username: " vpnuser
    read -p "Enter your OpenVPN password (visible as you type): " vpnpass
    # Use the correct user's home for mkdir and file creation
    mkdir -p "$(dirname "$CREDENTIALS_FILE")"
    echo "$vpnuser" > "$CREDENTIALS_FILE"
    echo "$vpnpass" >> "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    # Ensure owner is the original user, not root
    if [[ -n "$SUDO_USER" ]]; then
        sudo chown "$SUDO_USER":"$(id -gn $SUDO_USER)" -R "$(dirname "$CREDENTIALS_FILE")"
    fi
    echo "Credentials saved to: $CREDENTIALS_FILE"
    echo ""
fi

###################################
# - Save Configuration ----------- #
###################################
CONFIG_FILE="$USER_HOME/.openvpn/config.env"
# Ensure directory exists (using correct home)
mkdir -p "$(dirname "$CONFIG_FILE")"

# Save/Update NO_VPN_DOMAINS if provided
if [[ -n "$NO_VPN_DOMAINS_ARG" ]]; then
    echo "Saving NO_VPN_DOMAINS setting to $CONFIG_FILE..."
    # Create a temporary file
    TMP_CONFIG_FILE=$(mktemp)
    # Ensure tmp file is cleaned up on exit
    trap 'rm -f "$TMP_CONFIG_FILE"' EXIT

    # Write the new setting to the temp file
    echo "NO_VPN_DOMAINS=\"$NO_VPN_DOMAINS_ARG\"" > "$TMP_CONFIG_FILE"
    
    # Append other existing settings from original file (if any) to temp file
    if [[ -f "$CONFIG_FILE" ]]; then
        grep -v '^NO_VPN_DOMAINS=' "$CONFIG_FILE" >> "$TMP_CONFIG_FILE" 2>/dev/null || true
    fi
    
    # Replace the original config file with the updated temp file
    mv "$TMP_CONFIG_FILE" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    # Ensure owner is the original user, not root
    if [[ -n "$SUDO_USER" ]]; then
        sudo chown "$SUDO_USER":"$(id -gn $SUDO_USER)" "$CONFIG_FILE"
        sudo chown "$SUDO_USER":"$(id -gn $SUDO_USER)" "$(dirname "$CONFIG_FILE")"
    fi
    # Remove the trap for the specific temp file as it has been moved
    trap - EXIT
else
    # If the argument wasn't passed, check if the file exists
    # If it doesn't exist, create an empty one
    if [[ ! -f "$CONFIG_FILE" ]]; then
        touch "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        # Ensure owner is the original user, not root
        if [[ -n "$SUDO_USER" ]]; then
            sudo chown "$SUDO_USER":"$(id -gn $SUDO_USER)" "$CONFIG_FILE"
            sudo chown "$SUDO_USER":"$(id -gn $SUDO_USER)" "$(dirname "$CONFIG_FILE")"
        fi
        echo "Created empty config file: $CONFIG_FILE"
    fi
fi

###################################
# - Install Scripts -------------- #
###################################
echo "Installing scripts..."

# Install openvpn_connect.sh
sudo install -m 755 scripts/openvpn_connect.sh /usr/local/bin/openvpn_connect.sh
CREATED_FILES+=("/usr/local/bin/openvpn_connect.sh")

# Install openvpn-down.sh
sudo install -m 755 scripts/openvpn-down.sh /usr/local/bin/openvpn-down.sh
CREATED_FILES+=("/usr/local/bin/openvpn-down.sh")

# Install connectivity check script and service if a domain is provided
if [[ -n "$CONNECTIVITY_CHECK_DOMAIN" ]]; then
    echo "Installing connectivity check for domain: $CONNECTIVITY_CHECK_DOMAIN"
    
    # Install the script
    CONNECTIVITY_SCRIPT_TARGET="/usr/local/bin/openvpn_connectivity_check.sh"
    sudo install -m 755 scripts/openvpn_connectivity_check.sh "$CONNECTIVITY_SCRIPT_TARGET"
    CREATED_FILES+=("$CONNECTIVITY_SCRIPT_TARGET")
    
    # Prepare and install the service file
    SERVICE_SOURCE="systemd/openvpn_connectivity_check.service"
    SERVICE_TARGET="/etc/systemd/system/openvpn_connectivity_check.service"
    TEMP_SERVICE_FILE=$(mktemp)

    # Replace placeholders in the service file
    sed -e "s|%%CONNECTIVITY_CHECK_DOMAIN%%|$CONNECTIVITY_CHECK_DOMAIN|" \
        -e "s|%%CONNECTIVITY_SCRIPT_PATH%%|$CONNECTIVITY_SCRIPT_TARGET|" \
        "$SERVICE_SOURCE" > "$TEMP_SERVICE_FILE"

    sudo install -m 644 "$TEMP_SERVICE_FILE" "$SERVICE_TARGET"
    rm "$TEMP_SERVICE_FILE" # Clean up temp file
    CREATED_FILES+=("$SERVICE_TARGET")
    
    # Enable and start the service
    sudo systemctl daemon-reload
    sudo systemctl enable openvpn_connectivity_check.service > /dev/null 2>&1 || true
    # Use restart instead of start to ensure it picks up changes if already running
    sudo systemctl restart openvpn_connectivity_check.service || echo -e "${YELLOW}Warning: Failed to start connectivity check service. Check 'systemctl status openvpn_connectivity_check.service' and 'journalctl -u openvpn_connectivity_check.service' for details.${ENDCOLOR}"
    CREATED_CONNECTIVITY_SERVICE=true
fi

###################################
# - Install Desktop Shortcuts ---- #
###################################
echo "Installing desktop shortcuts..."

DESKTOP_DIR="$HOME/Desktop"
mkdir -p "$DESKTOP_DIR"

# Install connect shortcut
install -m 755 desktop/openvpn_connect.desktop "$DESKTOP_DIR/openvpn_connect.desktop"
gio set "$DESKTOP_DIR/openvpn_connect.desktop" metadata::trusted true 2>/dev/null || true
CREATED_FILES+=("$DESKTOP_DIR/openvpn_connect.desktop")

# Install disconnect shortcut
install -m 755 desktop/openvpn_disconnect.desktop "$DESKTOP_DIR/openvpn_disconnect.desktop"
gio set "$DESKTOP_DIR/openvpn_disconnect.desktop" metadata::trusted true 2>/dev/null || true
CREATED_FILES+=("$DESKTOP_DIR/openvpn_disconnect.desktop")

###################################
# - Setup SysMonitor Indicator ---- #
###################################
if [[ ! -f "$HOME/.indicator-sysmonitor.json" ]]; then
    echo "Setting up SysMonitor Indicator..."
    if ! grep -q "fossfreedom/indicator-sysmonitor" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
      sudo add-apt-repository ppa:fossfreedom/indicator-sysmonitor -y > /dev/null 2>&1 || true
    fi
    sudo apt-get update > /dev/null 2>&1 || true
    sudo apt-get install -y indicator-sysmonitor > /dev/null 2>&1 || true

    cat <<'EOF' > "$HOME/.indicator-sysmonitor.json"
{
  "custom_text": "{openvpn}",
  "interval": 2.0,
  "on_startup": false,
  "sensors": {
    "openvpn": [
      "Check VPN connection status",
      "pgrep -f \"^openvpn\" > /dev/null && echo \"VPN running\" || echo \"VPN not running\""
    ]
  }
}
EOF
    CREATED_INDICATOR_CONFIG=true

    sudo pkill -f '.*indicator-sysmonitor' 2>/dev/null || true
    (
        indicator-sysmonitor >/dev/null 2>&1 &
        indicator_pid=$!
        sleep 3
        if ! kill -0 "$indicator_pid" 2>/dev/null; then
            echo -e "${YELLOW}Failed to start SysMonitor Indicator. You may need to launch it manually.${ENDCOLOR}"
        fi
    ) || true
else
    echo "~/.indicator-sysmonitor.json already exists, skipping SysMonitor Indicator setup."
fi

###################################
# -----------  Done  ------------ #
###################################
echo -e "${GREEN}OpenVPN setup script completed successfully!${ENDCOLOR}"
echo ""
echo "Next steps:"
echo "1) Place one or more .ovpn files in ~/Downloads. The newest one will be used when you click the desktop icon."
echo "2) If you see 'Allow Launching' warnings on the desktop icons, right-click them and select 'Allow Launching'."