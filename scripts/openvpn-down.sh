#!/bin/bash
sudo -u $(whoami) DISPLAY=${DISPLAY} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u $(whoami))/bus notify-send -u critical "OpenVPN connection closed." 