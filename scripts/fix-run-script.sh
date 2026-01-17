#!/bin/bash
# Fix the gopher run script to use MIX_ENV=prod
# Run with: sudo ./scripts/fix-run-script.sh

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo"
    exit 1
fi

echo "Fixing /Users/gopher/run-gopher.sh..."

cat > /Users/gopher/run-gopher.sh << 'EOF'
#!/bin/zsh
# PureGopherAI launch script
# Called by launchd to start the server

source /Users/gopher/.zshrc
cd /Users/gopher/pure_gopher_ai
export MIX_ENV=prod
exec /opt/homebrew/bin/mix run --no-halt >> /Users/gopher/.gopher/server.log 2>&1
EOF

chown gopher:staff /Users/gopher/run-gopher.sh
chmod +x /Users/gopher/run-gopher.sh

echo "Restarting service..."
launchctl stop com.puregopherai.server
sleep 2
launchctl start com.puregopherai.server

echo "Waiting for startup..."
sleep 5

echo "Testing..."
echo "" | nc -w 3 localhost 70 | head -5

echo ""
echo "Done!"
