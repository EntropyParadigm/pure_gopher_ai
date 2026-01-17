#!/bin/bash
# Update phlog entries and sync to gopher user
# Run with: sudo ./scripts/update-phlog.sh

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo"
    exit 1
fi

echo "=== Updating Phlog Entries ==="

# Copy phlog entries from main user to gopher user
echo "Step 1: Copying phlog entries..."
cp -r /Users/anthonyramirez/.gopher/phlog/2026 /Users/gopher/.gopher/phlog/
chown -R gopher:staff /Users/gopher/.gopher/phlog/2026

echo "Step 2: Listing phlog entries..."
find /Users/gopher/.gopher/phlog -name "*.txt" | sort

# Sync code and restart
echo "Step 3: Syncing code..."
rsync -av --delete /Users/anthonyramirez/pure_gopher_ai/lib/ /Users/gopher/pure_gopher_ai/lib/
chown -R gopher:staff /Users/gopher/pure_gopher_ai/lib

echo "Step 4: Recompiling..."
sudo -u gopher -H bash -c 'source ~/.zshrc && cd ~/pure_gopher_ai && /opt/homebrew/bin/mix compile'

echo "Step 5: Restarting service..."
launchctl stop com.puregopherai.server
sleep 2
launchctl start com.puregopherai.server

echo "Step 6: Waiting for startup..."
sleep 5

echo "Step 7: Testing phlog..."
echo "/phlog" | nc -w 3 localhost 70 | head -15

echo ""
echo "=== Done ==="
