#!/bin/bash
# Enable Tor listener for PureGopherAI
# Run with: sudo ./scripts/enable-tor.sh

set -e

PLIST="/Library/LaunchDaemons/com.puregopherai.server.plist"

echo "=== Enabling Tor Listener ==="

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo"
    exit 1
fi

echo "Step 1: Updating plist..."
/usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:TOR_ENABLED true" "$PLIST"

# Add TOR_PORT if not exists
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:TOR_PORT string 7071" "$PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:TOR_PORT 7071" "$PLIST"

# Add ONION_ADDRESS if not exists
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:ONION_ADDRESS string 4la36s6x44qfs5bktepwmbvrg2spz5etdons5a3cg2k7gfmwjkb7wqad.onion" "$PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:ONION_ADDRESS 4la36s6x44qfs5bktepwmbvrg2spz5etdons5a3cg2k7gfmwjkb7wqad.onion" "$PLIST"

echo "Step 2: Restarting service..."
launchctl stop com.puregopherai.server
sleep 2
launchctl start com.puregopherai.server
sleep 3

echo "Step 3: Verifying..."
if lsof -i :7071 2>/dev/null | grep -q beam; then
    echo "✓ Tor listener running on port 7071"
else
    echo "✗ Tor listener not detected"
    echo "Checking logs..."
    tail -10 /Users/gopher/.gopher/server.log | grep -iE "tor|7071|error"
fi

echo ""
echo "Done!"
