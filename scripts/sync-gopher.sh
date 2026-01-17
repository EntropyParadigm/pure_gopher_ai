#!/bin/bash
# Sync code changes to gopher user and restart service
# Run with: sudo ./scripts/sync-gopher.sh

set -e

echo "=== Syncing code to gopher user ==="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo"
    exit 1
fi

# Sync lib directory
echo "Step 1: Syncing lib files..."
rsync -av --delete /Users/anthonyramirez/pure_gopher_ai/lib/ /Users/gopher/pure_gopher_ai/lib/
chown -R gopher:staff /Users/gopher/pure_gopher_ai/lib

# Sync config if changed
echo "Step 2: Syncing config files..."
rsync -av /Users/anthonyramirez/pure_gopher_ai/config/ /Users/gopher/pure_gopher_ai/config/
chown -R gopher:staff /Users/gopher/pure_gopher_ai/config

# Recompile
echo "Step 3: Recompiling..."
sudo -u gopher -H bash -c 'source ~/.zshrc && cd ~/pure_gopher_ai && /opt/homebrew/bin/mix compile'

# Restart service
echo "Step 4: Restarting service..."
launchctl stop com.puregopherai.server
sleep 2
launchctl start com.puregopherai.server

# Verify
echo "Step 5: Verifying..."
sleep 3

echo ""
echo "=== Health Check ==="
echo "/health" | nc -w 3 localhost 70 | grep -A2 "Uptime:" || echo "Could not get health"

echo ""
echo "=== Done ==="
