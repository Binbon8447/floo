# Expose Home Media Server (Emby/Plex/Jellyfin)

## What This Does

Makes your **home media server accessible from anywhere** on the internet, even though it's behind your home router/NAT.

**Perfect for:** Accessing your Emby/Plex library while traveling, sharing with family/friends.

## The Setup

```
Your Home (MacBook behind NAT)           Public Server (Raspberry Pi)
┌─────────────────────┐                 ┌──────────────────────┐
│  Emby on :8096      │                 │  Public IP           │
│  ↓                  │                 │  ↓                   │
│  flooc (client) ────┼──Encrypted──────┤  floos (server)      │
│                     │    Tunnel       │  ↓                   │
└─────────────────────┘                 │  Listens on :8096    │
                                        └──────────┬───────────┘
                                                   │
                                        Friends connect here!
                                        http://YOUR_SERVER_IP:8096
```

## Step-by-Step Setup

### 1. Generate Secure Passwords

```bash
# Generate strong PSK and token
PSK=$(openssl rand -base64 32)
TOKEN=$(openssl rand -base64 32)
echo "PSK: $PSK"
echo "TOKEN: $TOKEN"
```

Copy these values - you'll need them for both configs.

### 2. Configure Public Server (Raspberry Pi / VPS)

**File:** `floos.toml`

```toml
port = 8443                    # Tunnel port (can be any port, e.g., 443, 8443)
host = "0.0.0.0"              # Listen on all interfaces
cipher = "aegis128l"           # Fast on ARM, use aes256gcm on x86_64
psk = "YOUR_PSK_HERE"         # Paste PSK from step 1
default_token = "YOUR_TOKEN_HERE"  # Paste token from step 1

[server.services.emby]
id = 1
mode = "reverse"               # Server listens, client provides service
local_port = 8096             # What port users connect to
target_host = "127.0.0.1"     # Client will connect to its localhost
target_port = 8096            # Emby port on client machine
```

**Start the server:**
```bash
./floos floos.toml
```

**Expected output:**
```
[SERVER] Listening on 0.0.0.0:8443
[READY] Server ready
```

### 3. Configure Home Machine (MacBook / Home Server)

**File:** `flooc.toml`

```toml
remote_host = "YOUR_SERVER_IP"     # Public IP of your RPI/VPS
remote_port = 8443                  # Must match server port
cipher = "aegis128l"                # Must match server cipher
psk = "YOUR_PSK_HERE"              # Same PSK as server
default_token = "YOUR_TOKEN_HERE"  # Same token as server
service_id = 1                      # Which service to connect to
num_tunnels = 1                     # Number of parallel tunnels
reconnect_enabled = true            # Auto-reconnect if drops
```

**Start the client:**
```bash
./flooc flooc.toml
```

**Expected output:**
```
[TUNNEL 0] Connected to YOUR_SERVER_IP:8443
[CLIENT] Tunnel handler started
```

### 4. Access Your Media Server

From **anywhere** (friends, your phone, etc.):
```
http://YOUR_SERVER_IP:8096
```

No Floo client needed! Just open in web browser.

## How It Works

1. **flooc** on your home machine connects to **floos** on public server
2. Encrypted tunnel established (AEGIS-128L, 29 Gbps capable)
3. **floos** starts listening on public port 8096
4. When someone connects to `http://SERVER_IP:8096`:
   - floos accepts connection
   - Sends request through encrypted tunnel to flooc
   - flooc connects to localhost:8096 (Emby)
   - Data flows: User ← floos ← Tunnel ← flooc ← Emby
5. Everything encrypted end-to-end!

## Troubleshooting

### Can't Connect to Server

```bash
# On home machine, test connection:
./flooc --ping flooc.toml

# Should show:
# [OK] Connected to YOUR_SERVER_IP:8443
# [OK] Handshake completed
```

If fails:
- Check `remote_host` is correct public IP
- Check firewall allows port 8443 on server
- Verify PSK and cipher match exactly

### flooc Connects But Can't Access Emby

```bash
# On home machine, verify Emby is running:
curl http://localhost:8096

# Should return Emby web page
```

If Emby not accessible:
- Start Emby server
- Check Emby is on port 8096
- Try `http://127.0.0.1:8096` in browser

### PSK/Token Mismatch

Error: `Connection closed` or `Authentication failed`

**Fix:** Ensure PSK and token are EXACTLY the same in both configs (including quotes, spaces).

## Security Notes

- ✅ **End-to-end encrypted:** AEGIS-128L cipher (hardware accelerated)
- ✅ **Two-layer auth:** PSK for tunnel + token for service
- ✅ **Automatic reconnection:** If connection drops, auto-reconnects
- ⚠️ **Change default passwords!** Never use "CHANGE-ME" in production

## Performance

- **Throughput:** 29.4 Gbps on M1 Macs (AEGIS-128L)
- **Latency:** <1ms overhead for local network, +network latency for internet
- **Streams:** Supports multiple concurrent users watching Emby

## Advanced: Custom Port

Want Emby on standard port 80 or 443?

Server config:
```toml
local_port = 80  # or 443
```

**Note:** Ports below 1024 require root/sudo on Linux.

## What Users Need

**Friends/Family accessing your Emby:**
- Just the URL: `http://YOUR_SERVER_IP:8096`
- Nothing else! No Floo, no VPN, just web browser

**You (managing the tunnel):**
- Correct PSK and token in configs
- flooc running on home machine
- floos running on public server
