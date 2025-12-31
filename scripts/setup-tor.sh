#!/bin/bash
# Setup Tor hidden service for PureGopherAI
# Run with sudo: sudo ./scripts/setup-tor.sh

set -e

HIDDEN_SERVICE_DIR="/var/lib/tor/pure_gopher_ai"
TORRC="/etc/tor/torrc"

echo "=== PureGopherAI Tor Hidden Service Setup ==="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo"
    exit 1
fi

# Check if Tor is installed
if ! command -v tor &> /dev/null; then
    echo "Tor is not installed. Installing..."
    if command -v pacman &> /dev/null; then
        pacman -S tor --noconfirm
    elif command -v apt &> /dev/null; then
        apt install tor -y
    elif command -v brew &> /dev/null; then
        brew install tor
    else
        echo "Please install Tor manually"
        exit 1
    fi
fi

# Create hidden service directory
mkdir -p "$HIDDEN_SERVICE_DIR"
chown -R tor:tor "$HIDDEN_SERVICE_DIR"
chmod 700 "$HIDDEN_SERVICE_DIR"

# Add hidden service config to torrc if not present
if ! grep -q "HiddenServiceDir $HIDDEN_SERVICE_DIR" "$TORRC" 2>/dev/null; then
    echo "" >> "$TORRC"
    echo "# PureGopherAI Hidden Service" >> "$TORRC"
    echo "HiddenServiceDir $HIDDEN_SERVICE_DIR/" >> "$TORRC"
    echo "HiddenServicePort 70 127.0.0.1:7071" >> "$TORRC"
    echo "Added hidden service config to $TORRC"
else
    echo "Hidden service already configured in $TORRC"
fi

# Restart Tor
echo "Restarting Tor service..."
systemctl restart tor || service tor restart

# Wait for hidden service to be created
echo "Waiting for hidden service to initialize..."
sleep 5

# Display onion address
if [ -f "$HIDDEN_SERVICE_DIR/hostname" ]; then
    ONION_ADDRESS=$(cat "$HIDDEN_SERVICE_DIR/hostname")
    echo ""
    echo "=== SUCCESS ==="
    echo "Your .onion address: $ONION_ADDRESS"
    echo ""
    echo "Update your config/config.exs:"
    echo "  onion_address: \"$ONION_ADDRESS\""
    echo ""
    echo "Test with: torsocks nc $ONION_ADDRESS 70"
else
    echo "Hidden service not yet ready. Check: sudo cat $HIDDEN_SERVICE_DIR/hostname"
fi
