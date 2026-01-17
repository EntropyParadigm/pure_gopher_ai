#!/bin/bash
# Rebuild gopher user's dependencies from scratch
# Run with: sudo ./scripts/rebuild-gopher.sh

set -e

echo "=== Rebuilding PureGopherAI for gopher user ==="

# Stop the service
echo "Step 1: Stopping service..."
launchctl stop com.puregopherai.server 2>/dev/null || true
sleep 2

# Clean build artifacts completely
echo "Step 2: Cleaning build artifacts..."
sudo -u gopher rm -rf /Users/gopher/pure_gopher_ai/_build
sudo -u gopher rm -rf /Users/gopher/pure_gopher_ai/deps

# Get deps and recompile as gopher user
echo "Step 3: Getting dependencies..."
sudo -u gopher -H bash -c 'source ~/.zshrc && cd ~/pure_gopher_ai && /opt/homebrew/bin/mix deps.get'

echo "Step 4: Compiling (this may take a few minutes)..."
sudo -u gopher -H bash -c 'source ~/.zshrc && cd ~/pure_gopher_ai && MIX_ENV=prod /opt/homebrew/bin/mix compile'

# Restart service
echo "Step 5: Restarting service..."
launchctl start com.puregopherai.server

# Wait and check
echo "Step 6: Waiting for startup..."
sleep 5

echo ""
echo "=== Checking status ==="
tail -10 /Users/gopher/.gopher/server.log | grep -E "listening|Started|error" || echo "Check logs manually"

echo ""
echo "Testing connection..."
echo "" | nc -w 3 localhost 70 | head -3 || echo "Server not responding yet"
