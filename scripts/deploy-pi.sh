#!/usr/bin/env bash
#
# Build and OTA-deploy PureGopherAI firmware to the Raspberry Pi (Nerves).
#
# Usage:  ./scripts/deploy-pi.sh [device]
#   device defaults to nerves.local; pass an IP to override (e.g. 192.168.1.2)
#   NERVES_SSH_KEY overrides the ssh key (default ~/.ssh/id_ed25519)
#
# This exists because four things silently break the device if you just run
# `mix firmware && mix upload` (as older docs said):
#
#   1. MIX_ENV=prod FAILS to compile (warnings-as-errors in the Bumblebee ML
#      code in model_registry.ex), so firmware MUST build in the default dev env.
#   2. dev defaults the gopher port to 7070 -> the server refuses :70 and the
#      public tunnel serves nothing. We force GOPHER_PORT=70.
#   3. config/target.exs bakes BURROW_TOKEN at COMPILE time with no default;
#      without it PureGopherAi.Tunnel logs "No token configured" and never
#      connects to the relay. Keep BURROW_TOKEN in .env (sourced below).
#   4. `mix upload` needs a TTY and hangs when scripted, so we stream the .fw
#      straight to the device's fwup SSH subsystem instead. Nerves then auto-
#      reverts an UNVALIDATED image on the next reboot, so we immediately call
#      Nerves.Runtime.validate_firmware() once the new image boots.
#
set -euo pipefail

DEVICE="${1:-nerves.local}"
SSH_KEY="${NERVES_SSH_KEY:-$HOME/.ssh/id_ed25519}"
cd "$(cd "$(dirname "$0")/.." && pwd)"

# --- credentials + build config -------------------------------------------
# shellcheck disable=SC1091
[ -f .env ] && source .env
: "${BURROW_TOKEN:?BURROW_TOKEN not set. Add it to .env (value is the relay burrow.service --token).}"
: "${GEMINI_API_KEY:?GEMINI_API_KEY not set. Add it to .env.}"
export MIX_TARGET=rpi3
unset MIX_ENV                    # dev on purpose (prod fails --warnings-as-errors)
export GOPHER_PORT="${GOPHER_PORT:-70}"

echo "==> Building firmware (target=rpi3, env=dev, GOPHER_PORT=$GOPHER_PORT, BURROW_TOKEN=set)"
mix deps.get
mix firmware

FW="_build/rpi3_dev/nerves/images/pure_gopher_ai.fw"
[ -f "$FW" ] || { echo "ERROR: firmware not found at $FW"; exit 1; }

echo "==> Streaming firmware to $DEVICE via the fwup SSH subsystem"
cat "$FW" | ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "nerves@$DEVICE" -s fwup

echo "==> Waiting for the device to reboot into the new image"
sleep 8                                                   # let the reboot begin
until nc -z -G 2 "$DEVICE" 22 >/dev/null 2>&1; do sleep 3; done
sleep 8                                                   # let the app start

echo "==> Validating firmware (without this it auto-reverts on the next reboot)"
VCMD='IO.puts("VALIDATE=" <> inspect(Nerves.Runtime.validate_firmware())); Process.sleep(1500); IO.puts("TUNNEL=" <> inspect(PureGopherAi.Tunnel.status()[:status]))'
OUT="$(mktemp)"
# nerves_ssh IEx never exits on stdin EOF, so run it in the background and kill it.
ssh -tt -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "nerves@$DEVICE" <<<"$VCMD" >"$OUT" 2>&1 &
SPID=$!
sleep 10
kill -9 "$SPID" 2>/dev/null || true
tr -d '\r' < "$OUT" | grep -aE "VALIDATE=|TUNNEL=" || echo "(could not read validation output; check manually: ssh nerves@$DEVICE)"
rm -f "$OUT"

echo
echo "==> Deployed. Verify the public site through the relay:"
echo "    printf '\\r\\n' | nc gopherlab.org 70 | head"
