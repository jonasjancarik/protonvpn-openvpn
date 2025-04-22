# ProtonVPN OpenVPN Setup

A collection of scripts to set up and manage OpenVPN connections to ProtonVPN on Linux systems, with optional features for corporate environments.

## Features

- Easy installation and setup
- Automatic route injection for specified domains to bypass the VPN (`NO_VPN_DOMAINS`)
- Optional SSSD integration: Automatically discovers *all* configured SSSD domains and injects routes for their domain controllers.
- Optional domain connectivity check: Installs a service to monitor a specific domain and kill the VPN if the domain becomes unreachable.
- Desktop shortcuts for connect/disconnect
- Optional system tray indicator for VPN status (`indicator-sysmonitor`)

## Installation

1.  Clone this repository:
    ```bash
    git clone https://github.com/jonasjancarik/protonvpn-openvpn.git
    cd protonvpn-openvpn
    ```

2.  Run the installation script:
    ```bash
    ./install.sh [OPTIONS]
    ```
    **Options:**
    *   `--force`: Overwrite existing files installed by this script.
    *   `--check-domain <domain>`: Install and enable the connectivity check service. This service will periodically check if `<domain>` is resolvable via DNS. If it fails, any running OpenVPN process managed by these scripts will be terminated. This is useful to prevent lockouts in environments where VPN access might interfere with local domain authentication after a disconnect/reconnect.
    *   `--no-vpn-domains "<comma,separated,domains>"`: Save the specified list of domains to bypass the VPN. This setting is stored in `~/.openvpn/config.env` and used automatically by the connection script.

## Components

- `install.sh` - Main installation script
- `scripts/openvpn_connect.sh` - VPN connection script (handles route injection)
- `scripts/openvpn-down.sh` - VPN disconnect script
- `scripts/openvpn_connectivity_check.sh` - Optional domain connectivity monitor script
- `systemd/openvpn_connectivity_check.service` - Optional systemd service file for the connectivity monitor
- `desktop/openvpn_connect.desktop` - Connect desktop shortcut
- `desktop/openvpn_disconnect.desktop` - Disconnect desktop shortcut

## Requirements

- `openvpn`
- `dialog` (for the installer)
- `dnsutils` (provides `dig`, `nslookup`, `host` used for DNS resolution in scripts)
- `sssd-tools` (provides `sssctl`, only needed if using the `SSSD_DOMAIN` feature)
- `indicator-sysmonitor` (optional, for system tray indicator)

The installer (`install.sh`) attempts to install `openvpn`, `dialog`, `dnsutils`, and `indicator-sysmonitor` via `apt-get` if they are not found.

## Usage

1.  **Credentials:** Run `install.sh` first. It will prompt you to enter your special ProtonVPN OpenVPN username and password (from [https://account.protonvpn.com/account-password#openvpn](https://account.protonvpn.com/account-password#openvpn)) and save them to `~/.openvpn/credentials.txt`.
2.  **Bypass Domains (Optional):** During installation, you can use the `--no-vpn-domains "domain1,domain2"` flag to specify domains whose traffic should *not* go through the VPN. This setting is saved to `~/.openvpn/config.env`.
3.  **Configuration Files:** Download your desired ProtonVPN OpenVPN configuration files (`.ovpn`) from the ProtonVPN website.
4.  **Placement:** Place one or more `.ovpn` files in your `~/Downloads` directory. The `openvpn_connect.sh` script (and the desktop shortcut) will automatically use the *newest* `.ovpn` file found in that directory.
5.  **Connect/Disconnect:** Use the desktop shortcuts (`openvpn_connect.desktop`, `openvpn_disconnect.desktop`) or run `/usr/local/bin/openvpn_connect.sh` manually.
6.  **Monitor:** If `indicator-sysmonitor` was installed, monitor VPN status in the system tray.

## Configuration / Environment Variables

The behavior of `openvpn_connect.sh` can be modified:

- **Via Configuration File (`~/.openvpn/config.env`)**: 
    - The `NO_VPN_DOMAINS` setting is automatically read from this file if set during installation using the `--no-vpn-domains` flag.
- **Via Environment Variables (Overrides config file)**:
    - Setting `NO_VPN_DOMAINS` as an environment variable when running the script (`export NO_VPN_DOMAINS=...; openvpn_connect.sh`) will override the value stored in the configuration file for that specific run.

**Details of `NO_VPN_DOMAINS`**: 
- A comma-separated list of domain names.
- The script will resolve all A record IP addresses for these domains and add specific routes via your local gateway (`net_gateway`) to ensure traffic to these IPs does *not* go through the VPN tunnel.

**Note on SSSD Integration:**

- The script *automatically* attempts SSSD integration.
- It runs `sssctl domain-list` to find configured SSSD domains.
- If one or more domains are found, the script iterates through *each* domain.
- For each domain, it uses `sssctl domain-status` to discover its Active Directory Domain Controllers and adds routes for them via `net_gateway` to ensure authentication traffic bypasses the VPN.
- If `sssctl domain-status` fails for a specific domain (e.g., it's offline), a warning is printed, and the script continues to the next domain.
- If **zero** SSSD domains are found, this step is skipped.
- There is no longer an `SSSD_DOMAIN` environment variable to set.

## Optional Connectivity Check

If you installed the connectivity check service using `./install.sh --check-domain <your_domain>`, a systemd service (`openvpn_connectivity_check.service`) runs in the background.

- It uses `scripts/openvpn_connectivity_check.sh`.
- Periodically (every 10 seconds by default), it checks if `<your_domain>` can be resolved via DNS.
- If the domain becomes *unreachable*, the script assumes connectivity to essential local resources might be broken (e.g., SSSD auth) and forcefully terminates any running `openvpn` process.
- This helps prevent situations where the VPN connects successfully but breaks local network access required *before* the VPN is fully established.

## License

MIT License 