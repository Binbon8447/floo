# Expose Multiple Services (Media Server + SSH)

## What This Does

Expose **multiple services** from your home network through one public server:
- **Emby/Plex** for friends and family
- **SSH** for remote administration

Both through one encrypted tunnel!

## The Setup

```
Home Network (Behind NAT)               Public Server
┌────────────────────────┐             ┌─────────────────────┐
│ Emby on :8096         │             │ Listens on :8096    │←─ Friends
│ SSH on :22            │             │ Listens on :2222    │←─ You (admin)
│ ↓                     │             │ ↑                   │
│ flooc (ONE instance) ─┼─Encrypted───┤ floos               │
└────────────────────────┘   Tunnel   └─────────────────────┘
```

**Key insight:** ONE flooc on your home machine serves BOTH services!

## Step-by-Step Setup

### 1. Generate Passwords

```bash
openssl rand -base64 32  # PSK
openssl rand -base64 32  # Token
```

### 2. Server Config (Public Server)

**File:** `floos.toml`

```toml
port = 8443
host = "0.0.0.0"
cipher = "aegis128l"
psk = "YOUR_PSK"
default_token = "YOUR_TOKEN"  # Used for BOTH services (simplified)

# Media server
[server.services.emby]
id = 1
mode = "reverse"
local_port = 8096      # Public Emby port
target_host = "127.0.0.1"
target_port = 8096

# SSH access
[server.services.ssh]
id = 2
mode = "reverse"
local_port = 2222      # Public SSH port (not 22 for security)
target_host = "127.0.0.1"
target_port = 22
```

**Start:**
```bash
./floos floos.toml
```

### 3. Client Config (Home Machine)

**File:** `flooc.toml`

```toml
remote_host = "YOUR_SERVER_IP"
remote_port = 8443
cipher = "aegis128l"
psk = "YOUR_PSK"              # Same as server
default_token = "YOUR_TOKEN"  # Same as server
num_tunnels = 2               # Two tunnels for reliability
reconnect_enabled = true
```

**Start:**
```bash
./flooc flooc.toml
```

**That's it!** One flooc serves both Emby and SSH.

### 4. Access Your Services

**Emby (anyone):**
```
http://YOUR_SERVER_IP:8096
```

**SSH (you):**
```bash
ssh -p 2222 user@YOUR_SERVER_IP
```

## How It Works

When flooc starts:
1. Connects to floos
2. floos sees TWO reverse services (Emby + SSH)
3. floos opens TWO public ports: 8096 and 2222
4. When user connects to either port:
   - floos forwards through tunnel to flooc
   - flooc connects to appropriate local service
   - Data flows through encrypted tunnel

## Advanced: Different Access Control

Want to give friends Emby access but NOT SSH?

**Server config:**
```toml
default_token = "friends-can-have-this"

[server.services.emby]
id = 1
# Uses default_token (friends have this)

[server.services.ssh]
id = 2
token = "admin-secret-dont-share"  # Override for SSH only
```

**Friend's flooc config:**
```toml
default_token = "friends-can-have-this"
service_id = 1  # Only Emby
```

**Your flooc config:**
```toml
default_token = "admin-secret-dont-share"
service_id = 2  # Only SSH
```

Now friends can access Emby but not your SSH!

## Troubleshooting

### Only One Service Works

**Check:** Are both services defined in server config?
```bash
./floos --doctor floos.toml
# Should show: Configuration parsed (services: 2)
```

### SSH Works But Emby Doesn't (or vice versa)

**Check:** Are the services actually running on home machine?
```bash
# On home machine:
curl http://localhost:8096  # Test Emby
ssh localhost               # Test SSH
```

### Port 2222 Already in Use

**Solution:** Change `local_port` in server config:
```toml
[server.services.ssh]
local_port = 2223  # Use different port
```

Then access with: `ssh -p 2223 user@YOUR_SERVER_IP`

## Security

- ✅ All traffic encrypted (AEGIS-128L)
- ✅ Two-factor: PSK + token authentication
- ✅ Per-service access control (optional)
- ⚠️ SSH on non-standard port (security through obscurity)
- ⚠️ Consider SSH key-only auth (disable password login)

## Performance

Both services share the tunnel bandwidth:
- **With 2 tunnels:** ~58 Gbps theoretical (2 × 29 Gbps)
- **Practical:** Depends on your internet upload speed
- **Concurrent users:** Multiple users can use different services simultaneously

No performance impact - encryption is hardware-accelerated!
