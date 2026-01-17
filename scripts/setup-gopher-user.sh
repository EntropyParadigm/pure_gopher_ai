#!/bin/bash
# Setup dedicated unprivileged gopher user for PureGopherAI
# Run with sudo: sudo ./scripts/setup-gopher-user.sh
#
# This script creates a dedicated 'gopher' user to run the server
# with minimal privileges while preserving Metal GPU access.

set -e

GOPHER_USER="gopher"
GOPHER_HOME="/Users/gopher"
GOPHER_UID="599"
GOPHER_GID="20"  # staff group
SOURCE_USER="${SUDO_USER:-$(whoami)}"
SOURCE_HOME="/Users/$SOURCE_USER"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== PureGopherAI Dedicated User Setup ==="
echo "Source user: $SOURCE_USER"
echo "Source home: $SOURCE_HOME"
echo "Project dir: $PROJECT_DIR"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

# Check if gopher user already exists
if dscl . -read /Users/$GOPHER_USER &>/dev/null; then
    echo "User '$GOPHER_USER' already exists."
    read -p "Do you want to continue and update the setup? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        exit 0
    fi
else
    echo "Step 1: Creating user '$GOPHER_USER'..."
    dscl . -create /Users/$GOPHER_USER
    dscl . -create /Users/$GOPHER_USER UserShell /bin/zsh
    dscl . -create /Users/$GOPHER_USER RealName "Gopher Server"
    dscl . -create /Users/$GOPHER_USER UniqueID $GOPHER_UID
    dscl . -create /Users/$GOPHER_USER PrimaryGroupID $GOPHER_GID
    dscl . -create /Users/$GOPHER_USER NFSHomeDirectory $GOPHER_HOME
    echo "  Created user with UID $GOPHER_UID"
fi

# Create home directory
echo "Step 2: Creating home directory..."
mkdir -p $GOPHER_HOME
chown $GOPHER_USER:staff $GOPHER_HOME
chmod 755 $GOPHER_HOME
echo "  Created $GOPHER_HOME"

# Create data directory structure
echo "Step 3: Creating data directory structure..."
sudo -u $GOPHER_USER mkdir -p $GOPHER_HOME/.gopher/{data,backups,phlog,docs,gemini,finger,plugins}
chmod 750 $GOPHER_HOME/.gopher
chmod 700 $GOPHER_HOME/.gopher/data
chmod 700 $GOPHER_HOME/.gopher/backups
chmod 700 $GOPHER_HOME/.gopher/gemini
echo "  Created ~/.gopher directory structure"

# Migrate existing data if present
if [ -d "$SOURCE_HOME/.gopher" ]; then
    echo "Step 4: Migrating existing data from $SOURCE_HOME/.gopher..."
    cp -R $SOURCE_HOME/.gopher/* $GOPHER_HOME/.gopher/ 2>/dev/null || true
    chown -R $GOPHER_USER:staff $GOPHER_HOME/.gopher
    echo "  Migrated existing data"
else
    echo "Step 4: No existing ~/.gopher data to migrate (skipped)"
fi

# Copy project files
echo "Step 5: Copying project files..."
if [ -d "$GOPHER_HOME/pure_gopher_ai" ]; then
    echo "  Project directory exists, updating..."
    rm -rf $GOPHER_HOME/pure_gopher_ai/_build
    rm -rf $GOPHER_HOME/pure_gopher_ai/deps
fi
cp -R $PROJECT_DIR $GOPHER_HOME/pure_gopher_ai
chown -R $GOPHER_USER:staff $GOPHER_HOME/pure_gopher_ai
echo "  Copied project to $GOPHER_HOME/pure_gopher_ai"

# Copy libtorch if present
if [ -d "$SOURCE_HOME/libtorch" ]; then
    echo "Step 6: Copying libtorch for Metal GPU support..."
    cp -R $SOURCE_HOME/libtorch $GOPHER_HOME/libtorch
    chown -R $GOPHER_USER:staff $GOPHER_HOME/libtorch
    echo "  Copied libtorch to $GOPHER_HOME/libtorch"
else
    echo "Step 6: No libtorch found at $SOURCE_HOME/libtorch (skipped)"
    echo "  Metal GPU acceleration may not work without libtorch"
fi

# Set up HuggingFace cache
echo "Step 7: Setting up HuggingFace model cache..."
sudo -u $GOPHER_USER mkdir -p $GOPHER_HOME/.cache/huggingface
echo "  Created ~/.cache/huggingface"

# Create .zshrc
echo "Step 8: Creating environment file..."
cat > $GOPHER_HOME/.zshrc << 'EOF'
# PureGopherAI environment configuration

# ARM Homebrew (must be first)
export PATH="/opt/homebrew/bin:$PATH"

# Torchx / libtorch for Metal GPU
export LIBTORCH_DIR=/Users/gopher/libtorch/libtorch

# Elixir/Mix configuration
export MIX_ENV=prod

# Server configuration
export GOPHER_PORT=70
export TOR_ENABLED=false

# Uncomment if using Tor:
# export ONION_ADDRESS="your-address.onion"
# export TOR_ENABLED=true
EOF
chown $GOPHER_USER:staff $GOPHER_HOME/.zshrc
echo "  Created $GOPHER_HOME/.zshrc"

# Create launch script
echo "Step 9: Creating launch script..."
cat > $GOPHER_HOME/run-gopher.sh << 'EOF'
#!/bin/zsh
# PureGopherAI launch script
# Called by launchd to start the server

source /Users/gopher/.zshrc
cd /Users/gopher/pure_gopher_ai
exec /opt/homebrew/bin/mix run --no-halt >> /Users/gopher/.gopher/server.log 2>&1
EOF
chmod +x $GOPHER_HOME/run-gopher.sh
chown $GOPHER_USER:staff $GOPHER_HOME/run-gopher.sh
echo "  Created $GOPHER_HOME/run-gopher.sh"

# Create launchd plist
echo "Step 10: Creating launchd service..."
cat > /Library/LaunchDaemons/com.puregopherai.server.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.puregopherai.server</string>

    <key>UserName</key>
    <string>gopher</string>

    <key>GroupName</key>
    <string>staff</string>

    <key>Program</key>
    <string>/Users/gopher/run-gopher.sh</string>

    <key>WorkingDirectory</key>
    <string>/Users/gopher/pure_gopher_ai</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/bin:/bin</string>
        <key>LIBTORCH_DIR</key>
        <string>/Users/gopher/libtorch/libtorch</string>
        <key>MIX_ENV</key>
        <string>prod</string>
        <key>GOPHER_PORT</key>
        <string>70</string>
        <key>TOR_ENABLED</key>
        <string>false</string>
        <key>HOME</key>
        <string>/Users/gopher</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/Users/gopher/.gopher/server.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/gopher/.gopher/server-error.log</string>
</dict>
</plist>
EOF
echo "  Created /Library/LaunchDaemons/com.puregopherai.server.plist"

# Compile dependencies as gopher user
echo "Step 11: Compiling dependencies as gopher user..."
echo "  This may take a few minutes on first run..."
sudo -u $GOPHER_USER -i bash -c 'cd ~/pure_gopher_ai && /opt/homebrew/bin/mix local.hex --force && /opt/homebrew/bin/mix local.rebar --force && /opt/homebrew/bin/mix deps.get && /opt/homebrew/bin/mix compile'
echo "  Dependencies compiled"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "The launchd service has been created but NOT loaded yet."
echo ""
echo "To start the service:"
echo "  sudo launchctl load /Library/LaunchDaemons/com.puregopherai.server.plist"
echo "  sudo launchctl start com.puregopherai.server"
echo ""
echo "To verify:"
echo "  sudo launchctl list | grep puregopher"
echo "  echo '' | nc localhost 70"
echo "  tail -f /Users/gopher/.gopher/server.log"
echo ""
echo "Service management:"
echo "  Stop:    sudo launchctl stop com.puregopherai.server"
echo "  Start:   sudo launchctl start com.puregopherai.server"
echo "  Unload:  sudo launchctl unload /Library/LaunchDaemons/com.puregopherai.server.plist"
echo ""
echo "Security verification:"
echo "  sudo -u gopher ls /Users/$SOURCE_USER  # Should fail with permission denied"
echo ""
