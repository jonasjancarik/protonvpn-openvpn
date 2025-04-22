#!/bin/bash
# This script should be run as the REGULAR USER.
# It will use 'sudo' internally for commands that require root privileges.

set -e

# Check if running as root, which is not intended
if [[ "$(id -u)" -eq 0 ]]; then
   echo -e "\e[31mError: This script should be run as a regular user, not with sudo or as root.\e[0m"
   echo "It will ask for your password via sudo when needed."
   exit 1
fi

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
        # Use sudo for system files, regular rm for user files
        if [[ "$file" == /usr/local/bin/* || "$file" == /etc/systemd/system/* ]]; then
          # Ask for sudo password only if necessary
          sudo rm -f "$file"
        elif [[ "$file" == "$HOME"* ]]; then
          # Files in user's home directory
          rm -f "$file"
        else
           echo -e "${YELLOW}Warning: Unknown file location for cleanup: $file. Trying rm.${ENDCOLOR}"
           rm -f "$file" || true # Try removing without sudo first
        fi
      fi
    done
    # If we created the domain connectivity check service, stop and disable it.
    if $CREATED_CONNECTIVITY_SERVICE; then
      # Need sudo for systemctl and removing system file
      echo "Stopping and disabling connectivity check service..."
      sudo systemctl stop openvpn_connectivity_check.service > /dev/null 2>&1 || true
      sudo systemctl disable openvpn_connectivity_check.service > /dev/null 2>&1 || true
      sudo rm -f /etc/systemd/system/openvpn_connectivity_check.service
    fi
    # Optionally, remove indicator config if it was created. (Runs as user)
    if $CREATED_INDICATOR_CONFIG; then
      echo "Removing indicator config $HOME/.indicator-sysmonitor.json..."
      rm -f "$HOME/.indicator-sysmonitor.json"
    fi
    # We don't typically remove the config file on cleanup unless explicitly asked
  fi
}

trap cleanup EXIT

###################################
# ------ Script Banner ---------- #
###################################
echo "===================================================="
echo "=                                                  ="
echo "=      ProtonVPN OpenVPN Setup Script (v0.1)       ="
echo "=   (Run as regular user, uses sudo internally)    ="
echo "=                                                  ="
echo "===================================================="
echo ""
echo "This script will install OpenVPN components and helpers."
echo "You may be prompted for your password ('sudo') for system-wide changes."
echo ""
echo -e "${YELLOW}IMPORTANT:${ENDCOLOR} You will need your special OpenVPN username and password from:"
echo "  https://account.protonvpn.com/account-password#openvpn"
echo "They are NOT the same as your normal ProtonVPN login credentials!"
echo ""

###################################
# --- Install Prerequisites ----- #
###################################
echo "Installing/checking dependencies..."

# Function to check if a package is installed
is_installed() {
  dpkg -s "$1" &> /dev/null
}

# Update apt cache once at the beginning
sudo apt-get update -y > /dev/null 2>&1 || echo -e "${YELLOW}Warning: apt-get update failed. Proceeding anyway...${ENDCOLOR}"

if ! command -v openvpn &>/dev/null || ! is_installed openvpn; then
    echo "Installing openvpn..."
    sudo apt-get install -y openvpn > /dev/null 2>&1 || { echo -e "${RED}Error: Failed to install openvpn.${ENDCOLOR}"; exit 1; }
fi

if ! command -v dialog &>/dev/null || ! is_installed dialog; then
    echo "Installing dialog..."
    sudo apt-get install -y dialog > /dev/null 2>&1 || { echo -e "${RED}Error: Failed to install dialog.${ENDCOLOR}"; exit 1; }
fi

if ! command -v nslookup &>/dev/null && ! command -v host &>/dev/null || ! is_installed dnsutils; then
    echo "Installing dnsutils..."
    sudo apt-get install -y dnsutils > /dev/null 2>&1 || { echo -e "${RED}Error: Failed to install dnsutils.${ENDCOLOR}"; exit 1; }
fi

###################################
# - Prompt for OpenVPN Credentials #
###################################
CREDENTIALS_FILE="$HOME/.openvpn/credentials.txt"
CONFIG_DIR="$(dirname "$CREDENTIALS_FILE")"

# Create config dir as user if it doesn't exist
mkdir -p "$CONFIG_DIR"

if [[ ! -s "$CREDENTIALS_FILE" ]] || $FORCE_FLAG; then
    if [[ -s "$CREDENTIALS_FILE" ]] && $FORCE_FLAG; then
         echo -e "${YELLOW}Overwriting existing OpenVPN credentials due to --force flag.${ENDCOLOR}"
    else
         echo "No OpenVPN credentials found at $CREDENTIALS_FILE."
    fi
    echo "Please provide your special OpenVPN username and password from ProtonVPN."
    echo "They are available here: https://account.protonvpn.com/account-password#openvpn"
    echo -e "${YELLOW}(Note: Your input will be visible as you type.)${ENDCOLOR}"
    echo ""
    read -p "Enter your OpenVPN username: " vpnuser
    read -p "Enter your OpenVPN password (visible as you type): " vpnpass # Changed back from -sp
    echo "" # Newline after password entry

    # Write credentials as user
    echo "$vpnuser" > "$CREDENTIALS_FILE"
    echo "$vpnpass" >> "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE" # Set permissions as user
    echo "Credentials saved to: $CREDENTIALS_FILE"
    echo ""
else
    echo "Existing OpenVPN credentials found at $CREDENTIALS_FILE. Use --force to overwrite."
fi

###################################
# - Save Configuration ----------- #
###################################
CONFIG_FILE="$HOME/.openvpn/config.env"
# Ensure directory exists (as user)
mkdir -p "$(dirname "$CONFIG_FILE")"

# Save/Update NO_VPN_DOMAINS if provided, or create if not exists
if [[ -n "$NO_VPN_DOMAINS_ARG" ]] || [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Saving configuration to $CONFIG_FILE..."
    # Create a temporary file (as user)
    TMP_CONFIG_FILE=$(mktemp)
    # Ensure tmp file is cleaned up on exit
    trap 'rm -f "$TMP_CONFIG_FILE"' EXIT

    if [[ -n "$NO_VPN_DOMAINS_ARG" ]]; then
        echo "NO_VPN_DOMAINS=\"$NO_VPN_DOMAINS_ARG\"" > "$TMP_CONFIG_FILE"
    fi

    # Append other existing settings from original file (if any and --force not set)
    if [[ -f "$CONFIG_FILE" ]] && ! $FORCE_FLAG; then
        grep -v '^NO_VPN_DOMAINS=' "$CONFIG_FILE" >> "$TMP_CONFIG_FILE" 2>/dev/null || true
    fi

    # Replace the original config file with the updated temp file (as user)
    mv "$TMP_CONFIG_FILE" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" # Set permissions as user
    # Remove the trap for the specific temp file as it has been moved
    trap - EXIT
else
    echo "Existing config file found at $CONFIG_FILE. Use --force to overwrite."
fi


###################################
# - Install Scripts -------------- #
###################################
echo "Installing scripts to /usr/local/bin..."

# Install scripts requires sudo because the target is /usr/local/bin
sudo install -m 755 scripts/openvpn_connect.sh /usr/local/bin/openvpn_connect.sh
CREATED_FILES+=("/usr/local/bin/openvpn_connect.sh")

sudo install -m 755 scripts/openvpn-down.sh /usr/local/bin/openvpn-down.sh
CREATED_FILES+=("/usr/local/bin/openvpn-down.sh")

# Install connectivity check script and service if a domain is provided
if [[ -n "$CONNECTIVITY_CHECK_DOMAIN" ]]; then
    echo "Installing connectivity check for domain: $CONNECTIVITY_CHECK_DOMAIN..."

    # Install the script (needs sudo)
    CONNECTIVITY_SCRIPT_TARGET="/usr/local/bin/openvpn_connectivity_check.sh"
    sudo install -m 755 scripts/openvpn_connectivity_check.sh "$CONNECTIVITY_SCRIPT_TARGET"
    CREATED_FILES+=("$CONNECTIVITY_SCRIPT_TARGET")

    # Prepare and install the service file (needs sudo)
    SERVICE_SOURCE="systemd/openvpn_connectivity_check.service"
    SERVICE_TARGET="/etc/systemd/system/openvpn_connectivity_check.service"
    TEMP_SERVICE_FILE=$(mktemp)

    # Replace placeholders in the service file
    sed -e "s|%%CONNECTIVITY_CHECK_DOMAIN%%|$CONNECTIVITY_CHECK_DOMAIN|" \
        -e "s|%%CONNECTIVITY_SCRIPT_PATH%%|$CONNECTIVITY_SCRIPT_TARGET|" \
        "$SERVICE_SOURCE" > "$TEMP_SERVICE_FILE"

    sudo install -m 644 "$TEMP_SERVICE_FILE" "$SERVICE_TARGET"
    rm "$TEMP_SERVICE_FILE" # Clean up temp file (as user)
    CREATED_FILES+=("$SERVICE_TARGET")

    # Enable and start the service (needs sudo)
    echo "Reloading systemd daemon, enabling and starting service..."
    sudo systemctl daemon-reload
    sudo systemctl enable openvpn_connectivity_check.service > /dev/null 2>&1 || true
    # Use restart instead of start to ensure it picks up changes if already running
    sudo systemctl restart openvpn_connectivity_check.service || echo -e "${YELLOW}Warning: Failed to start connectivity check service. Check 'sudo systemctl status openvpn_connectivity_check.service' and 'sudo journalctl -u openvpn_connectivity_check.service' for details.${ENDCOLOR}"
    CREATED_CONNECTIVITY_SERVICE=true
fi

###################################
# - Install Desktop Shortcuts ---- #
###################################
echo "Installing desktop shortcuts to $HOME/Desktop..."

DESKTOP_DIR="$HOME/Desktop"
mkdir -p "$DESKTOP_DIR" # Create as user

# Install shortcuts as user to user's Desktop
install -m 755 desktop/openvpn_connect.desktop "$DESKTOP_DIR/openvpn_connect.desktop"
gio set "$DESKTOP_DIR/openvpn_connect.desktop" metadata::trusted true 2>/dev/null || true # Runs as user
CREATED_FILES+=("$DESKTOP_DIR/openvpn_connect.desktop")

install -m 755 desktop/openvpn_disconnect.desktop "$DESKTOP_DIR/openvpn_disconnect.desktop"
gio set "$DESKTOP_DIR/openvpn_disconnect.desktop" metadata::trusted true 2>/dev/null || true # Runs as user
CREATED_FILES+=("$DESKTOP_DIR/openvpn_disconnect.desktop")

###################################
# - Setup SysMonitor Indicator ---- #
###################################
# Check if the file doesn't exist OR the force flag is set
if [[ ! -f "$HOME/.indicator-sysmonitor.json" || "$FORCE_FLAG" == "true" ]]; then
    echo "Setting up SysMonitor Indicator..."

    # --- PPA and Package Installation (needs sudo) ---
    if ! grep -qr "fossfreedom/indicator-sysmonitor" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
      echo "Adding indicator-sysmonitor PPA..."
      sudo add-apt-repository ppa:fossfreedom/indicator-sysmonitor -y > /dev/null 2>&1 || { echo -e "${YELLOW}Warning: Failed to add PPA. Indicator might not install.${ENDCOLOR}"; }
      echo "Updating package list after adding PPA..."
      sudo apt-get update > /dev/null 2>&1 || true # Update after adding PPA
    fi

    if ! is_installed indicator-sysmonitor; then
        echo "Installing indicator-sysmonitor package..."
        sudo apt-get install -y indicator-sysmonitor > /dev/null 2>&1 || { echo -e "${RED}Error: Failed to install indicator-sysmonitor.${ENDCOLOR}"; exit 1; }
    else
        echo "indicator-sysmonitor package already installed."
    fi
    # --- End PPA/Package Installation ---

    # --- Config File Creation (as user) ---
    INDICATOR_CONFIG_FILE="$HOME/.indicator-sysmonitor.json"
    mkdir -p "$(dirname "$INDICATOR_CONFIG_FILE")" # Create config dir as user

    echo "Creating/updating $INDICATOR_CONFIG_FILE..."
    cat <<EOF > "$INDICATOR_CONFIG_FILE"
{
  "custom_text": "{openvpn}",
  "interval": 2.0,
  "on_startup": true,
  "sensors": {
    "openvpn": [
      "Check VPN connection status",
      "pgrep -f \"^openvpn\" > /dev/null && echo \"VPN running\" || echo \"VPN not running\""
    ]
  }
}
EOF
    chmod 600 "$INDICATOR_CONFIG_FILE" # Set permissions as user
    CREATED_INDICATOR_CONFIG=true # Mark that we created/overwrote the config
    # --- End Config File Creation ---

    # --- Restart Indicator (as user) ---
    echo "Restarting SysMonitor Indicator (as user)..."
    if command -v indicator-sysmonitor &>/dev/null; then
        # Kill existing indicator owned by the current user
        pkill -f 'indicator-sysmonitor' 2>/dev/null || true
        sleep 1 # Give it a moment to die

        # Start indicator as the current user
        indicator-sysmonitor >/dev/null 2>&1 & disown
        sleep 3 # Give it time to start

        # Check if it's running
        if pgrep -u "$USER" -f indicator-sysmonitor > /dev/null; then
            echo "SysMonitor Indicator started successfully."
        else
            echo -e "${YELLOW}Warning: Failed to start SysMonitor Indicator. You may need to launch it manually.${ENDCOLOR}"
        fi
    else
        echo -e "${YELLOW}Warning: 'indicator-sysmonitor' command not found. Cannot start indicator.${ENDCOLOR}"
    fi
    # --- End Restart Indicator ---

else
    echo "~/.indicator-sysmonitor.json already exists, skipping SysMonitor Indicator setup. Use --force to overwrite."
fi

###################################
# -----------  Done  ------------ #
###################################
echo ""
echo -e "${GREEN}OpenVPN setup script completed successfully!${ENDCOLOR}"
echo ""
echo "Next steps:"
echo "1) Place one or more .ovpn files in ~/Downloads. The newest one will be used when you click the desktop icon."
echo "2) If you see 'Allow Launching' warnings on the desktop icons, right-click them and select 'Allow Launching'."
echo "3) You may need to log out and log back in for the SysMonitor Indicator to appear correctly if 'on_startup' was set."

exit 0