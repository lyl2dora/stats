#!/bin/sh

set -u

HELPER_LABEL="zone.lyl.stats.SMC.Helper"

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    HOME=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')
fi

run_as_user() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" "$@"
    else
        "$@"
    fi
}

echo "Uninstalling Stats..."

run_as_user osascript -e 'quit app "Stats"' >/dev/null 2>&1 || true

echo "Removing the SMC helper (administrator privileges are required)..."
sudo launchctl bootout "system/$HELPER_LABEL" 2>/dev/null || true
sudo launchctl unload "/Library/LaunchDaemons/$HELPER_LABEL.plist" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$HELPER_LABEL.plist"
sudo rm -f "/Library/PrivilegedHelperTools/$HELPER_LABEL"

for app in "/Applications/Stats.app" "$HOME/Applications/Stats.app"; do
    if [ -d "$app" ]; then
        echo "Removing $app..."
        sudo rm -rf "$app"
    fi
done

echo "Removing application data and preferences..."
rm -rf "$HOME/Library/Application Support/Stats"
rm -rf "$HOME/Library/Containers/zone.lyl.stats.Widgets"
rm -rf "$HOME/Library/Group Containers/"*.zone.lyl.stats.widgets
run_as_user defaults delete zone.lyl.stats >/dev/null 2>&1 || true
run_as_user defaults delete zone.lyl.stats.Widgets >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/zone.lyl.stats.plist"
rm -f "$HOME/Library/Preferences/zone.lyl.stats.Widgets.plist"

echo "Stats has been uninstalled."
echo "If fan speeds were controlled manually, they will return to automatic control after a reboot."
