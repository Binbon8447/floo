# Expose a Home Media Server

Use Floo's reverse tunneling mode to publish Jellyfin/Emby/Plex from your home
network through a small VPS. Visitors connect to the VPS; Floo relays the
traffic over an encrypted tunnel back to your LAN.

## Topology

```
 Home Network                         VPS / Cloud Host
 ┌──────────────┐                     ┌────────────────────────┐
 │  flooc       │  TLS/Noise tunnel   │        floos           │
 │  Jellyfin    │ ─────────────────▶ │  Listens on :80        │
 │  127.0.0.1   │                     │  Forwards to flooc     │
 └──────────────┘                     └────────────────────────┘
```

## 1. Generate secrets

```bash
PSK=$(openssl rand -base64 32)
TOKEN=$(openssl rand -base64 32)
echo "PSK=${PSK}"
echo "TOKEN=${TOKEN}"
```

## 2. Configure the server (`floos.toml`)

```toml
bind = "0.0.0.0"
port = 8443
cipher = "aes256gcm"
psk = "${PSK}"
token = "${TOKEN}"

[reverse_services]
webapp = "0.0.0.0:80"
```

Optional tuning (already included in the template) keeps long‑lived media
sessions healthy: TCP keepalive, larger socket buffers, and 30 s heartbeats.

Start floos on the VPS:

```bash
./floos floos.toml
```

## 3. Configure the client (`flooc.toml`)

```toml
server = "YOUR_SERVER_IP:8443"
cipher = "aes256gcm"
psk = "${PSK}"
token = "${TOKEN}"

[reverse_services]
webapp = "127.0.0.1:8080"

[advanced]
num_tunnels = 2
reconnect_enabled = true
```

Run flooc on the machine that hosts Jellyfin:

```bash
./flooc flooc.toml
```

## 4. Verify

1. `./flooc --doctor flooc.toml` should report *Connected* and *Handshake
   completed*.
2. Visit `http://YOUR_SERVER_IP/` from the internet. The request lands on the
   VPS (port 80) and is relayed to `127.0.0.1:8080` back home.

## Troubleshooting

- **Handshake fails** – Confirm PSK, token, and cipher match exactly.
- **Public port closed** – Open/forward TCP 8443 and 80/443 on the VPS firewall.
- **No response from Jellyfin** – Ensure the service listens on the address from
  `flooc.toml` and that local firewalls allow loopback connections.

## Hardening tips

- Rotate PSKs/tokens periodically.
- Use HTTPS on the published port by running Floo behind nginx/traefik on the
  VPS if you need TLS certificates.
- Run `flooc` under a systemd service so it auto restarts on boot.
