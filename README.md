```
███████╗██╗      ██████╗  ██████╗
██╔════╝██║     ██╔═══██╗██╔═══██╗
█████╗  ██║     ██║   ██║██║   ██║
██╔══╝  ██║     ██║   ██║██║   ██║
██║     ███████╗╚██████╔╝╚██████╔╝
╚═╝     ╚══════╝ ╚═════╝  ╚═════╝
```

**High-throughput, token-authenticated tunneling built in Zig.**

Floo multiplexes TCP and UDP services through a Noise-protected transport, delivering **29+ Gbit/s encrypted throughput** on commodity hardware.

[![Language: Zig](https://img.shields.io/badge/language-Zig-orange.svg)](https://ziglang.org/)
[![Dependencies: 0](https://img.shields.io/badge/dependencies-0-green.svg)](build.zig.zon)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---


## ⚠️ Security Warning

**Before production deployment:**
1. **Replace placeholder PSK and tokens** in config files with strong, unique secrets
2. **Never expose tunnels with default credentials** (`benchmark-test-key`, `floo-bench-token`)
3. **Use encryption** - set `cipher = "aes256gcm"` (never `"none"` in production)
4. Run `--doctor` diagnostics to validate your configuration

---

## Feature Comparison

How does Floo compare to similar tools?

| Feature | Floo | Rathole | FRP |
|---------|------|---------|-----|
| **Language** | Zig | Rust | Go |
| **Dependencies** | **0** ⭐ | 27+ crates | 34+ packages |
| **Max Throughput (M1)** | **29.4 Gbps** ⭐ | 18.1 Gbps | 10.0 Gbps |
| **vs Rathole** | **+62%** faster | baseline | -45% slower |
| **vs FRP** | **+194%** faster | +81% faster | baseline |
| **Encryption** | Noise XX + PSK | Noise NK, TLS, WS | TLS |
| **Ciphers** | 5 AEAD (AEGIS, AES-GCM, ChaCha20) | ChaCha20-Poly1305 | TLS standard |
| **TCP Forwarding** | ✅ | ✅ | ✅ |
| **UDP Forwarding** | ✅ | ✅ | ✅ |
| **Multi-Service** | ✅ Per tunnel | ✅ Per tunnel | ✅ Per process |
| **Parallel Tunnels** | ✅ Round-robin (1-16) | 🔶 Not documented | ✅ Connection pool |
| **Token Auth** | ✅ Per-service + default | ✅ Per-service + default | ✅ Global + OIDC |
| **Hot Config Reload** | ✅ SIGHUP (both) | ✅ Dynamic services | ✅ Admin API |
| **Heartbeat** | ✅ Configurable | ✅ Configurable | ✅ Configurable |
| **Auto-Reconnect** | ✅ Exponential backoff | ✅ Exponential backoff | ✅ Reconnection |
| **Built-in Diagnostics** | ✅ `--doctor`, `--ping` | 🔶 Logging only | ✅ Dashboard, Prometheus |
| **Config Format** | TOML | TOML | TOML, INI, YAML |
| **CLI Overrides** | ✅ Port, host, target, proxy | 🔶 Limited | ✅ Via flags |
| **IPv6 Support** | ✅ | ✅ | ✅ |
| **Proxy Client** | ✅ SOCKS5, HTTP CONNECT | ✅ SOCKS5, HTTP | ✅ HTTP, SOCKS5 |
| **Compression** | ❌ Planned | ❌ | ✅ |
| **HTTP Features** | ❌ | ❌ | ✅ Virtual hosts, auth |
| **P2P Mode** | ❌ | ❌ | ✅ XTCP, STCP |
| **Load Balancing** | ✅ Round-robin tunnels | 🔶 Not documented | ✅ Multiple backends |
| **Binary Size** | **394 KB + 277 KB** ⭐ | ~1-2 MB each | ~12-13 MB compressed |
| **Platform** | macOS, Linux (Windows planned) | Linux, macOS, Windows | All platforms |

**Legend:** ✅ Supported | ❌ Not available | 🔶 Limited/unclear

**Floo's Unique Strengths:**

```
Dependencies:  Floo      ∅ (zero)          ⭐
               Rathole   ████████████████████████████ (27+ crates)
               FRP       █████████████████████████████████ (34+ packages)

Binary Size:   Floo      ▌ 671 KB total (394 KB + 277 KB)  ⭐
               Rathole   ████ ~2-4 MB total
               FRP       ████████████████████████████████ ~24+ MB total

Throughput:    Floo      ██████████████████████████████ 29.4 Gbps ⭐
               Rathole   ██████████████████ 18.1 Gbps
               FRP       ██████████ 10.0 Gbps
```

- 🎯 **Zero dependencies** - Only uses Zig stdlib (Rathole: 27+, FRP: 34+)
- 🚀 **62% faster than Rathole** with AEGIS-128L cipher on ARM
- 📦 **Smallest binaries** - 671 KB total (394 KB client + 277 KB server)
- 🔐 **5 AEAD ciphers** - Optimize for your hardware (AEGIS, AES-GCM, ChaCha20)
- 🔐 **Noise XX protocol** - Mutual authentication (Rathole uses Noise NK one-way)
- ⚡ **Explicit parallel tunnels** - Round-robin load balancing (1-16 configurable)
- 🔧 **CLI-first diagnostics** - Built-in `--doctor` and `--ping` (no dashboard needed)
- 🌐 **Proxy client** - SOCKS5 and HTTP CONNECT support (corporate-friendly)

> **Note:** All features verified against source repositories (Rathole v0.5.0, FRP v0.65.0). Benchmarks measured on identical hardware (Apple M1 MacBook Air) using `iperf3` with single stream. Dependencies counted from Cargo.toml/go.mod. Binary sizes measured from compiled/released artifacts.

---

## Features

- **🔐 Noise XX + PSK** authentication with AES-256-GCM, AES-128-GCM, ChaCha20-Poly1305, or AEGIS ciphers
- **🔄 Hot-reloadable TOML configs** - update settings without downtime (SIGHUP)
- **🚀 Multi-service multiplexing** - forward multiple TCP/UDP services through one tunnel
- **⚡ Parallel tunnel connections** with round-robin load balancing
- **💓 Heartbeat supervision** - automatic failure detection and reconnection
- **📊 Diagnostic tools** - `--doctor` and `--ping` modes validate setup
- **🎯 Token-based access control** - per-service authentication
- **🌐 Proxy client support** - SOCKS5 and HTTP CONNECT for restricted networks

---

## Performance

**Benchmark Results** (Apple M1 MacBook Air):

| Configuration | Throughput |
|--------------|-----------|
| Raw loopback | 99.8 Gbps |
| Floo (plaintext) | 34.8 Gbps |
| Floo (AEGIS-128L) | 29.4 Gbps ⭐ |
| Floo (AEGIS-256) | 24.5 Gbps |
| Rathole | 18.1 Gbps |
| Floo (AES-128-GCM) | 17.9 Gbps |
| Floo (AES-256-GCM) | 15.8 Gbps |
| FRP | 10.0 Gbps |
| Floo (ChaCha20-Poly1305) | 3.53 Gbps |

**Visual Comparison:**

```
Raw loopback        ████████████████████████████████████████████████████ 99.8 Gbps
Floo (plaintext)    █████████████████▌                                   34.8 Gbps
Floo (AEGIS-128L)   ██████████████▊ ⭐                                   29.4 Gbps
Floo (AEGIS-256)    ████████████▎                                        24.5 Gbps
Rathole             █████████▏                                           18.1 Gbps
Floo (AES-128-GCM)  █████████                                            17.9 Gbps
Floo (AES-256-GCM)  ████████                                             15.8 Gbps
FRP                 █████                                                10.0 Gbps
Floo (ChaCha20)     █▊                                                   3.53 Gbps
                    └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴────►
                    0    10    20    30    40    50    60    70    80    90   100 Gbps
```

**Key Takeaways:**
- **AEGIS ciphers** deliver the best encrypted performance (29.4 Gbps)
- **Floo outperforms alternatives** by 62% (vs Rathole) with AEGIS-128L
- Hardware acceleration (ARM crypto extensions) makes encryption nearly free
- Even AES-GCM maintains competitive throughput vs. plaintext alternatives

---

## Quick Start

### Requirements

- [Zig 0.15.x](https://ziglang.org/download/) (tested with 0.15.1)
- macOS 14+ or Linux (POSIX-compliant systems)
- `iperf3` for benchmarking (optional)

### Build

```bash
zig build -Doptimize=ReleaseFast
```

Binaries are generated in `zig-out/bin/`:
- `floos` - Tunnel server (277 KB)
- `flooc` - Tunnel client (394 KB)

**Pre-built binaries** are available from [GitHub Releases](https://github.com/YUX/floo/releases) for:
- Linux x86_64 (baseline + Haswell-optimized)
- Linux aarch64
- macOS x86_64
- macOS aarch64 (Apple Silicon)

### Basic Usage

1. **Create configs** from templates:
   ```bash
   cp floos.toml.example floos.toml
   cp flooc.toml.example flooc.toml
   ```

2. **⚠️ UPDATE SECRETS** in both files:
   ```toml
   psk = "your-strong-random-psk-here"
   default_token = "your-strong-random-token-here"
   ```

3. **Start a test service**:
   ```bash
   iperf3 -s -p 9000
   ```

4. **Run server**:
   ```bash
   ./zig-out/bin/floos floos.toml
   ```

5. **Run client** (in another terminal):
   ```bash
   ./zig-out/bin/flooc flooc.toml
   ```

6. **Connect to tunneled service**:
   ```bash
   iperf3 -c 127.0.0.1 -p 9001
   ```

---

## Command-Line Interface

### Server (`floos`)

#### Basic Syntax
```bash
floos [options] [config_path]
```

#### Options

| Option | Short | Description |
|--------|-------|-------------|
| `--help` | `-h` | Show help message and exit |
| `--version` | `-V` | Show version information and exit |
| `--doctor` | | Run comprehensive diagnostics and exit |
| `--ping` | | Probe configured services for reachability and exit |
| `--port PORT` | `-p` | Override listening port from config |

#### Examples

```bash
# Start server with default config (./floos.toml)
floos

# Start with custom config
floos /etc/floo/production.toml

# Run diagnostics before starting
floos --doctor

# Check if target services are reachable
floos --ping

# Override listening port (useful for testing)
floos -p 9000

# Combine port override with diagnostics
floos -p 9000 --doctor custom.toml
```

#### Doctor Mode Output

The `--doctor` mode performs comprehensive validation:

```
[OK] Config file accessible at floos.toml
[OK] Configuration parsed (services: 1)
[WARN] Using default PSK; replace before production
[OK] Bind check succeeded on 0.0.0.0:8000
[OK] Service 'primary' (1) reachable (127.0.0.1:9000) - connect 0.17 ms
```

**Checks performed:**
- ✅ Config file exists and parses correctly
- ✅ PSK/token security validation
- ✅ Port binding availability
- ✅ Target service reachability

---

### Client (`flooc`)

#### Basic Syntax
```bash
flooc [options] [config_path]
```

#### Options

| Option | Short | Description |
|--------|-------|-------------|
| `--help` | `-h` | Show help message and exit |
| `--version` | `-V` | Show version information and exit |
| `--doctor` | | Run comprehensive diagnostics and exit |
| `--ping` | | Measure handshake latency and exit |
| `--local PORT` | `-l` | Override local listening port |
| `--remote HOST[:PORT]` | `-r` | Override remote server address |
| `--target HOST[:PORT]` | `-t` | Override target application address |
| `--proxy URL` | `-x` | Connect via SOCKS5 or HTTP CONNECT proxy |

#### Examples

```bash
# Start client with default config (./flooc.toml)
flooc

# Start with custom config
flooc ~/configs/client.toml

# Run diagnostics
flooc --doctor

# Measure connection and handshake latency
flooc --ping

# Quick test against different server
flooc -r tunnel.example.com:8443 --ping

# Override local listener port
flooc -l 7777

# Override remote server (hostname or IP)
flooc -r 192.168.1.100:8000

# Override remote server with port
flooc -r tunnel.example.com:9000

# Override target application
flooc -t 10.0.0.50:8080

# Combine multiple overrides for ad-hoc tunneling
flooc -l 5000 -r server.com:443 -t 192.168.1.1:80

# IPv6 support
flooc -r "[::1]:8000" --ping
flooc -r "[2001:db8::1]:8443" --doctor

# Proxy support (connect to tunnel server via proxy)
flooc -x socks5://127.0.0.1:1080 --ping
flooc -x socks5://user:pass@proxy.corp.com:1080
flooc -x http://proxy.example.com:8080 --doctor
flooc -x http://user:pass@proxy.corp.com:8080
```

#### Doctor Mode Output

The `--doctor` mode validates your setup:

```
[OK] Config file accessible at flooc.toml
[OK] Configuration parsed (services: 0)
[OK] Remote 127.0.0.1:8000 resolves to 127.0.0.1:8000
[OK] Local port 9001 available on 127.0.0.1
[OK] Ping succeeded (connect 0.12 ms, handshake 0.64 ms)
```

**Checks performed:**
- ✅ Config file exists and parses correctly
- ✅ PSK/token security validation
- ✅ Remote server hostname resolves
- ✅ Local port is available
- ✅ Full connection + handshake test

#### Ping Mode Output

The `--ping` mode measures tunnel establishment latency:

```
Pinging 127.0.0.1:8000...
[OK] Connected to 127.0.0.1:8000
[OK] Handshake completed using cipher 'aegis128l'
    connect:  0.21 ms
    handshake:0.64 ms
    total:    0.91 ms
```

**Metrics reported:**
- **connect** - TCP connection establishment time
- **handshake** - Noise XX + PSK authentication time
- **total** - Complete tunnel setup time

---

## Configuration

### Server Example (`floos.toml`)

```toml
[server]
port = 8443
host = "0.0.0.0"
cipher = "aes256gcm"   # Options: aes256gcm, aes128gcm, chacha20poly1305, aegis128l, aegis256, none
psk = "CHANGE-ME-BEFORE-PRODUCTION"
default_token = "CHANGE-ME-BEFORE-PRODUCTION"
heartbeat_interval_seconds = 30

# Performance tuning
socket_buffer_size = 8_388_608  # 8 MiB for high-bandwidth links
tcp_nodelay = true
tcp_keepalive = true

# TCP service
[server.services.web]
id = 1
transport = "tcp"
target_host = "10.0.0.10"
target_port = 80
token = "web-service-secret-token"

# UDP service
[server.services.dns]
id = 2
transport = "udp"
target_host = "10.0.0.53"
target_port = 53
token = "dns-service-secret-token"
```

### Client Example (`flooc.toml`)

```toml
[client]
remote_host = "tunnel.example.com"
remote_port = 8443
num_tunnels = 4  # Parallel connections for load balancing
cipher = "aes256gcm"  # Must match server
psk = "CHANGE-ME-SAME-AS-SERVER"
default_token = "CHANGE-ME-SAME-AS-SERVER"

# Reconnection handling
reconnect_enabled = true
reconnect_initial_delay_ms = 1000
reconnect_max_delay_ms = 30000
heartbeat_timeout_seconds = 40

# TCP service
[client.services.web]
type = "tcp"
local_port = 8080
target_host = "10.0.0.10"
target_port = 80

# UDP service
[client.services.dns]
type = "udp"
local_port = 5353
target_host = "10.0.0.53"
target_port = 53
```

### Configuration Reload

Both client and server support hot config reload:
```bash
kill -HUP <pid>
```

Existing tunnels are closed and reconnected with new settings.

---

## Common Use Cases

### Quick Ad-Hoc Tunnel (No Config Files)

Create a temporary tunnel without writing config files:

```bash
# On server machine (exposing local service on port 3000)
floos -p 8443 --doctor  # Verify port is available

# On client machine (access remote service locally)
flooc -l 5000 -r server.example.com:8443 -t 127.0.0.1:3000 --ping
```

**Note:** This uses default PSK/tokens (insecure for production).

### Testing Different Ciphers

Compare cipher performance on your hardware:

```bash
# Test with AEGIS-128L (fastest on ARM)
flooc -r server:8000 --ping

# Edit config to try different ciphers:
# - aegis128l (fastest)
# - aegis256 (balanced)
# - aes128gcm (good on x86)
# - chacha20poly1305 (portable, slower)
```

### Using Proxy to Reach Tunnel Server

Connect to tunnel server through corporate/restricted network:

```bash
# Via SOCKS5 proxy (e.g., SSH tunnel: ssh -D 1080 jumphost)
flooc -x socks5://127.0.0.1:1080

# Via corporate HTTP proxy
flooc -x http://proxy.corp.com:8080

# With proxy authentication
flooc -x socks5://user:password@proxy.corp.com:1080
flooc -x http://user:password@proxy.corp.com:8080

# Test connectivity through proxy
flooc -x socks5://127.0.0.1:1080 --ping
```

**Config file approach:**
```toml
# flooc.toml
proxy_url = "socks5://127.0.0.1:1080"
# Or:
proxy_url = "http://user:pass@proxy.corp.com:8080"
```

### Multi-Service Setup

Forward multiple services through one tunnel:

**Server config:**
```toml
[server.services.web]
id = 1
transport = "tcp"
target_host = "10.0.0.10"
target_port = 80
token = "web-secret"

[server.services.dns]
id = 2
transport = "udp"
target_host = "10.0.0.53"
target_port = 53
token = "dns-secret"
```

**Client config:**
```toml
[client.services.web]
type = "tcp"
local_port = 8080
target_host = "10.0.0.10"
target_port = 80
token = "web-secret"

[client.services.dns]
type = "udp"
local_port = 5353
target_host = "10.0.0.53"
target_port = 53
token = "dns-secret"
```

Then connect:
- Web: `curl http://localhost:8080`
- DNS: `dig @localhost -p 5353 example.com`

### Hot Config Reload

Update settings without restarting:

```bash
# Edit config file
vim floos.toml

# Reload config (existing tunnels reconnect with new settings)
kill -HUP $(pgrep floos)

# Verify reload
tail -f /var/log/floos.log
# Look for: [RELOAD] Configuration reloaded successfully!
```

### Production Deployment Checklist

Before going live:

```bash
# 1. Generate strong secrets
PSK=$(openssl rand -base64 32)
TOKEN=$(openssl rand -base64 32)

# 2. Update configs
sed -i "s/benchmark-test-key/$PSK/" floos.toml
sed -i "s/floo-bench-token/$TOKEN/" floos.toml
sed -i "s/benchmark-test-key/$PSK/" flooc.toml
sed -i "s/floo-bench-token/$TOKEN/" flooc.toml

# 3. Run diagnostics
./zig-out/bin/floos --doctor floos.toml
./zig-out/bin/flooc --doctor flooc.toml

# 4. Test connectivity
./zig-out/bin/flooc --ping flooc.toml

# 5. Deploy
systemctl start floos
systemctl start flooc
```

---

## Troubleshooting

### Connection Refused

**Problem:** `flooc --ping` shows `error.ConnectionRefused`

**Solutions:**
```bash
# 1. Verify server is running
pgrep floos

# 2. Check server is listening on correct port
floos --doctor floos.toml

# 3. Test network connectivity
nc -zv server.example.com 8443

# 4. Check firewall rules
sudo iptables -L | grep 8443
```

### Authentication Failed

**Problem:** Client can't connect, handshake fails

**Solutions:**
```bash
# 1. Verify PSK matches on both sides
grep "psk =" floos.toml flooc.toml

# 2. Verify cipher matches
grep "cipher =" floos.toml flooc.toml

# 3. Run diagnostics
flooc --doctor flooc.toml
floos --doctor floos.toml
```

### Heartbeat Timeout

**Problem:** `[CLIENT] Heartbeat timeout! No heartbeat for Xms`

**Solutions:**
```bash
# 1. Check if server is sending heartbeats
grep "heartbeat_interval" floos.toml  # Should be > 0

# 2. Verify client timeout is reasonable
grep "heartbeat_timeout" flooc.toml  # Should be > server interval

# 3. Check network stability
ping -c 10 server.example.com
```

### Port Already in Use

**Problem:** `error.AddressInUse` when starting

**Solutions:**
```bash
# Find what's using the port
lsof -i :8000  # or netstat -tuln | grep 8000

# Kill the process
kill <PID>

# Or use different port
floos -p 8001
flooc -l 9002
```

### Target Service Unreachable

**Problem:** `[FAIL] Service unreachable` in `--ping` mode

**Solutions:**
```bash
# 1. Verify target service is running
nc -zv 127.0.0.1 9000

# 2. Check target_host/target_port in config
grep "target" floos.toml

# 3. Test from server host
ssh server.example.com
nc -zv 127.0.0.1 9000
```

### High Latency / Low Throughput

**Problem:** Slow performance

**Solutions:**
```bash
# 1. Use fastest cipher for your CPU
# ARM: aegis128l
# x86 with AES-NI: aes128gcm
# Others: aegis256

# 2. Increase socket buffers
socket_buffer_size = 8_388_608  # 8 MiB

# 3. Enable TCP tuning
tcp_nodelay = true
tcp_keepalive = true

# 4. Use more parallel tunnels
num_tunnels = 8  # Increase from 4

# 5. Benchmark to identify bottleneck
./run_benchmarks.sh
```

### Config Validation Errors

**Problem:** `error.MissingPsk`, `error.MissingToken`, `error.ServiceMissingId`

**Solutions:**
```bash
# Check config syntax
./zig-out/bin/floos --doctor floos.toml

# Common fixes:
# - Add PSK when cipher != "none"
# - Add service id field
# - Add target_host and target_port
# - Add token or default_token

# Use example configs as reference
diff floos.toml floos.toml.example
```

### Memory Leaks / High Memory Usage

**Problem:** Growing memory consumption

**Solutions:**
```bash
# 1. Check for UDP session buildup (client side)
# Sessions expire after udp_timeout_seconds
# Cleanup runs every second in UDP mode

# 2. Monitor with doctor mode
watch -n 5 "flooc --doctor flooc.toml"

# 3. Restart periodically (until session GC improves)
systemctl restart flooc
```

### Debugging Tips

```bash
# 1. Enable encryption profiling (SIGUSR1)
kill -USR1 $(pgrep floos)
# Check /tmp/floo_profile.log

# 2. Watch server logs
tail -f /var/log/floos.log

# 3. Check tunnel state
lsof -p $(pgrep floos)  # Shows all connections

# 4. Monitor with netstat
watch -n 1 "netstat -an | grep 8000"

# 5. Test with verbose iperf3
iperf3 -c localhost -p 9001 -V
```

---

## Benchmarking

Run the full benchmark suite:

```bash
./run_benchmarks.sh
```

This compares:
- Raw loopback baseline
- Floo (plaintext + all ciphers)
- FRP (if installed)
- Rathole (if installed)

Results are saved to:
- `/tmp/floo_benchmark_summary.tsv` - Summary table
- `/tmp/bench_<name>.log` - Individual iperf3 logs
- `/tmp/floo*_bench.log` - Tunnel logs

**Customize benchmarks:**
```bash
# Edit run_benchmarks.sh to adjust:
# - Test duration (default: 3 seconds)
# - Parallel streams (default: 4)
# - Ports and addresses
```

---

## Development

### Testing

```bash
zig build test
```

### Formatting

```bash
zig fmt src/*.zig
```

### Cross-Compilation

```bash
zig build release-all -Drelease_cpu=haswell
```

Generates binaries for:
- x86_64/aarch64 Linux
- x86_64/aarch64 macOS

With CPU-specific tuning (haswell, znver3, native, baseline).

---

## Architecture

```
┌─────────────┐                     ┌──────────────┐
│ Local App   │                     │ Target App   │
│ (127.0.0.1) │                     │ (10.0.0.10)  │
└──────┬──────┘                     └──────▲───────┘
       │                                   │
       │ TCP/UDP                           │ TCP/UDP
       ▼                                   │
┌─────────────┐    Encrypted Tunnel  ┌─────┴────────┐
│   flooc     ├─────────────────────►│    floos     │
│  (Client)   │◄─────────────────────┤  (Server)    │
└─────────────┘   Noise XX + PSK     └──────────────┘
   Round-robin                        Per-service
   4 tunnels                          multiplexing
```

**Key Components:**
- **Noise XX handshake** - Mutual authentication with X25519 + PSK
- **Frame protocol** - Length-prefixed messages (4-byte header)
- **Stream multiplexing** - (service_id, stream_id) tuple routing
- **Per-stream threads** - Parallel I/O for each connection
- **Atomic nonce management** - Lock-free encryption

---

## Roadmap

- [ ] io_uring backend for Linux (reduce context switches)
- [ ] Dynamic cipher negotiation
- [ ] QUIC/DTLS UDP tunnels
- [ ] Prometheus/OpenTelemetry exporters
- [ ] Buffer reuse (slab allocators)
- [ ] Zero-copy forwarding paths

---

## Contributing

Pull requests and issue reports welcome!

**Guidelines:**
1. Run `zig fmt` before committing
2. Add tests for new features
3. Update documentation
4. Ensure benchmarks don't regress

---

## License

See LICENSE file.

---

## Support

- **Issues**: https://github.com/yux/floo/issues
- **Discussions**: https://github.com/yux/floo/discussions

---

**Built with ❤️ in Zig**
