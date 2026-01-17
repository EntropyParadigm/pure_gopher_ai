#!/bin/bash
# Fix Burrow tunnel settings for gopher user

echo "Adding Burrow settings to /Users/gopher/.zshrc..."

sudo bash -c 'cat >> /Users/gopher/.zshrc << ENDOFFILE

# Burrow tunnel settings
export BURROW_TOKEN="CrYyQgTr0S6D5jrkswY7B43yvXWOKj9zPIL6cHxpFw0"
export BURROW_NOISE_PUBKEY="jLP+tx3QcjtOyky0p/PfvH09dbqNuGCOrKf/z7QvXWQ="
ENDOFFILE'

echo "Restarting service..."
sudo launchctl stop com.puregopherai.server
sleep 2
sudo launchctl start com.puregopherai.server

echo "Done. Checking logs..."
sleep 3
tail -10 /Users/gopher/.gopher/server.log | grep -i "tunnel\|burrow"
