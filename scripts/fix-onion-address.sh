#!/bin/bash
# Fix ONION_ADDRESS configuration for Tor hidden service
# Run with: sudo ./scripts/fix-onion-address.sh

set -e

ONION="4la36s6x44qfs5bktepwmbvrg2spz5etdons5a3cg2k7gfmwjkb7wqad.onion"

echo "=== Fixing ONION_ADDRESS Configuration ==="

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo"
    exit 1
fi

echo "Step 1: Updating gopher user's .zshrc..."
# Replace commented ONION_ADDRESS with actual value
sed -i '' 's|# export ONION_ADDRESS="your-address.onion"|export ONION_ADDRESS="'"$ONION"'"|' /Users/gopher/.zshrc

# Remove duplicate commented TOR_ENABLED if exists
sed -i '' '/^# export TOR_ENABLED=true$/d' /Users/gopher/.zshrc

# Verify the change
echo "  ONION_ADDRESS set to: $ONION"

echo "Step 2: Syncing lib files..."
rsync -av --delete /Users/anthonyramirez/pure_gopher_ai/lib/ /Users/gopher/pure_gopher_ai/lib/
chown -R gopher:staff /Users/gopher/pure_gopher_ai/lib

echo "Step 3: Recompiling with new environment..."
sudo -u gopher -H bash -c 'source ~/.zshrc && cd ~/pure_gopher_ai && /opt/homebrew/bin/mix compile'

echo "Step 4: Restarting service..."
launchctl stop com.puregopherai.server
sleep 2
launchctl start com.puregopherai.server
sleep 3

echo "Step 5: Verifying..."
echo ""
echo "=== Tor Listener Test ==="
echo "" | nc -w 3 127.0.0.1 7071 | head -5

echo ""
echo "=== Done ==="
