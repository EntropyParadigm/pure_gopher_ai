# PureGopherAI

A pure Elixir Gopher server (RFC 1436) with native AI inference via Bumblebee. Optimized for Apple Silicon with Metal GPU acceleration. Supports both clearnet and Tor hidden services.

## Features

- **Pure Elixir** - No external runtime dependencies (Python, Go, etc.)
- **Native AI** - Bumblebee + Nx for local GPU-accelerated inference
- **Apple Silicon Optimized** - Torchx backend with Metal MPS
- **Tor Support** - Built-in hidden service listener
- **OTP Supervision** - Fault-tolerant architecture

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │           OTP Supervisor                    │
                    │         (one_for_one strategy)              │
                    └─────────────────┬───────────────────────────┘
                                      │
            ┌─────────────────────────┼─────────────────────────┐
            │                         │                         │
            ▼                         ▼                         ▼
┌───────────────────┐   ┌───────────────────┐   ┌───────────────────┐
│   Nx.Serving      │   │  ThousandIsland   │   │  ThousandIsland   │
│   (AI Engine)     │   │  :clearnet        │   │  :tor             │
│                   │   │  0.0.0.0:7070     │   │  127.0.0.1:7071   │
│  ┌─────────────┐  │   └─────────┬─────────┘   └─────────┬─────────┘
│  │ Bumblebee   │  │             │                       │
│  │ GPT-2/Llama │  │             │                       │
│  └─────────────┘  │             │                       │
└─────────┬─────────┘             │                       │
          │                       ▼                       ▼
          │             ┌───────────────────────────────────────┐
          │             │         GopherHandler                 │
          │             │    (network-aware routing)            │
          │             │                                       │
          │             │  Selectors:                           │
          └────────────►│    /        → Root Menu               │
           generate()   │    /ask     → AI Query                │
                        │    /about   → Server Stats            │
                        └───────────────────────────────────────┘
```

## Ports

| Network   | Internal Port | External Port | Notes |
|-----------|---------------|---------------|-------|
| Clearnet  | 7070          | 7070          | Non-privileged, no root needed |
| Tor       | 7071          | 70            | Tor maps standard port 70 → local 7071 |

**Why not port 70?** Port 70 is the standard Gopher port but requires root (privileged port < 1024). Options:
- Keep 7070 for clearnet (many Gopher servers use non-standard ports)
- Use `setcap` to allow port 70 without root: `sudo setcap 'cap_net_bind_service=+ep' /path/to/beam.smp`
- Tor handles port mapping automatically (external 70 → internal 7071)

## Quick Start

```bash
# Clone
git clone https://github.com/EntropyParadigm/pure_gopher_ai.git
cd pure_gopher_ai

# Install dependencies
mix deps.get

# Run (first run downloads AI model ~500MB)
iex -S mix

# Test with netcat
echo "" | nc localhost 7070
echo "/ask What is Elixir?" | nc localhost 7070
```

## Connecting with Gopher Clients

### Clearnet (port 7070)

```bash
# Lynx (text browser)
lynx gopher://localhost:7070/

# Bombadillo
bombadillo gopher://localhost:7070

# sacc
sacc localhost 7070

# cgo
cgo -h localhost -p 7070

# gopher command (if available)
gopher -p 7070 localhost

# curl (basic test)
curl gopher://localhost:7070/
curl gopher://localhost:7070/0/ask%20What%20is%20Elixir
```

### Tor (.onion on port 70)

```bash
# Lynx via torsocks
torsocks lynx gopher://abc123.onion/

# Bombadillo with Tor proxy
bombadillo gopher://abc123.onion

# sacc via torsocks
torsocks sacc abc123.onion 70

# netcat via torsocks
torsocks sh -c 'echo "" | nc abc123.onion 70'
torsocks sh -c 'echo "/ask Hello" | nc abc123.onion 70'
```

**Note:** Tor connections use standard port 70, so most clients work without port specification.

### Using Standard Port 70 (Clearnet)

If you want clearnet clients to connect on port 70 without specifying a port:

```bash
# Option 1: setcap (recommended - no root at runtime)
sudo setcap 'cap_net_bind_service=+ep' $(which erl)
# Then update config: clearnet_port: 70

# Option 2: iptables redirect
sudo iptables -t nat -A PREROUTING -p tcp --dport 70 -j REDIRECT --to-port 7070

# Option 3: socat proxy
socat TCP-LISTEN:70,fork,reuseaddr TCP:localhost:7070
```

## Tor Hidden Service Setup

### Automated Setup

```bash
sudo ./scripts/setup-tor.sh
```

### Manual Setup

1. Install Tor:
   ```bash
   # Arch Linux
   sudo pacman -S tor

   # macOS
   brew install tor

   # Debian/Ubuntu
   sudo apt install tor
   ```

2. Configure hidden service in `/etc/tor/torrc`:
   ```
   HiddenServiceDir /var/lib/tor/pure_gopher_ai/
   HiddenServicePort 70 127.0.0.1:7071
   ```

3. Restart Tor:
   ```bash
   sudo systemctl restart tor
   ```

4. Get your .onion address:
   ```bash
   sudo cat /var/lib/tor/pure_gopher_ai/hostname
   # Example: abc123xyz456.onion
   ```

5. Update `config/config.exs`:
   ```elixir
   config :pure_gopher_ai,
     onion_address: "abc123xyz456.onion"
   ```

6. Test via Tor:
   ```bash
   torsocks nc abc123xyz456.onion 70
   ```

## Configuration

Edit `config/config.exs`:

```elixir
config :pure_gopher_ai,
  # Clearnet
  clearnet_port: 7070,
  clearnet_host: "localhost",

  # Tor
  tor_enabled: true,
  tor_port: 7071,
  onion_address: "your-address.onion"
```

## Hardware Detection

The server automatically selects the optimal compute backend:

| Platform | Backend | Acceleration |
|----------|---------|--------------|
| macOS (Apple Silicon) | Torchx | Metal MPS GPU |
| Linux/Other | EXLA | CPU |

## Gopher Protocol

### Selectors

| Selector | Type | Description |
|----------|------|-------------|
| `/` | Menu | Root directory |
| `/ask <query>` | Text | AI-generated response |
| `/about` | Text | Server statistics |

### Response Types

- `i` - Info text (non-selectable)
- `0` - Text file
- `1` - Directory/Menu
- `3` - Error

## Dependencies

- `thousand_island` - TCP server
- `bumblebee` - Hugging Face model loading
- `nx` - Numerical computing
- `exla` - XLA backend (CPU/CUDA)
- `torchx` - PyTorch backend (Metal MPS)

## Production

```bash
# Build release
MIX_ENV=prod mix release

# Run
_build/prod/rel/pure_gopher_ai/bin/pure_gopher_ai start
```

## License

MIT
