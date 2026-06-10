import Config

# Nerves target-specific configuration
# This file is only imported when MIX_TARGET is set to a device target (e.g., rpi3).
# It overrides defaults from config.exs for embedded operation.

# --- Logging ---
# Use in-memory ring logger (no console on embedded devices)
config :logger, backends: [RingLogger]

# --- Networking ---
# Ethernet with DHCP (primary network interface)
config :vintage_net,
  regulatory_domain: "US",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }}
  ]

# Add WiFi if WIFI_SSID is set at compile time
if System.get_env("WIFI_SSID") do
  config :vintage_net,
    config: [
      {"usb0", %{type: VintageNetDirect}},
      {"eth0",
       %{
         type: VintageNetEthernet,
         ipv4: %{method: :dhcp}
       }},
      {"wlan0",
       %{
         type: VintageNetWiFi,
         vintage_net_wifi: %{
           networks: [
             %{
               key_mgmt: :wpa_psk,
               ssid: System.get_env("WIFI_SSID"),
               psk: System.get_env("WIFI_PSK")
             }
           ]
         },
         ipv4: %{method: :dhcp}
       }}
    ]
end

# --- NTP ---
# Critical for TLS certificate validation (Gemini protocol, API calls)
config :nerves_time, :servers, [
  "0.pool.ntp.org",
  "1.pool.ntp.org",
  "2.pool.ntp.org",
  "3.pool.ntp.org"
]

# --- SSH Access ---
# Remote IEx shell for debugging and maintenance
config :nerves_ssh,
  authorized_keys: [
    File.read!(Path.join(System.user_home!(), ".ssh/id_ed25519.pub"))
  ]

# --- Boot Order ---
config :shoehorn,
  init: [:nerves_runtime, :nerves_pack, :nerves_time],
  app: Mix.Project.config()[:app]

# --- AI Backend ---
# Pi uses Google Gemini Flash API (no local ML - only 1GB RAM)
config :pure_gopher_ai,
  ai_backend: :gemini_api,
  gemini_api_key: System.get_env("GEMINI_API_KEY"),
  gemini_model: System.get_env("GEMINI_MODEL", "gemini-2.5-flash"),
  gemini_timeout: 120_000

# --- Filesystem Paths ---
# Nerves writable partition at /data (persists across firmware updates)
config :pure_gopher_ai,
  content_dir: "/data/gopher",
  data_dir: "/data/gopher/data",
  phlog_dir: "/data/gopher/phlog",
  rag_docs_dir: "/data/gopher/docs",
  backup_dir: "/data/gopher/backups",
  blocklist_file: "/data/gopher/blocklist.txt",
  gemini_cert_file: "/data/gopher/gemini/cert.pem",
  gemini_key_file: "/data/gopher/gemini/key.pem",
  finger_plan_dir: "/data/gopher/finger",
  plugins_dir: "/data/gopher/plugins",
  tor_data_dir: "/data/tor"

# --- Burrow Tunnel ---
# On Nerves, runtime env vars don't exist. Bake the token at compile time.
# Set BURROW_TOKEN env var before running: MIX_TARGET=rpi3 mix firmware
config :pure_gopher_ai, :tunnel,
  enabled: true,
  server: System.get_env("BURROW_SERVER", "gopherlab.org:4000"),
  token: System.get_env("BURROW_TOKEN"),
  encryption: :noise,
  noise_server_pubkey: System.get_env("BURROW_NOISE_PUBKEY", "jLP+tx3QcjtOyky0p/PfvH09dbqNuGCOrKf/z7QvXWQ="),
  reconnect: true,
  tunnels: [
    [name: "gopher", local: 70, remote: 70],
    [name: "gemini", local: 1965, remote: 1965],
    [name: "ssh", local: 22, remote: 48372]
  ]

# --- Memory-Sensitive Tuning ---
# Pi 3B has only 1GB RAM - reduce memory usage
config :pure_gopher_ai,
  rag_embeddings_enabled: false,
  cache_max_entries: 100,
  conversation_max_messages: 5,
  cache_ttl_ms: 1_800_000,
  phlog_entries_per_page: 5
