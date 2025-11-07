# Floo

[![Language: Zig](https://img.shields.io/badge/language-Zig-orange.svg)](https://ziglang.org/)
[![Dependencies: 0](https://img.shields.io/badge/dependencies-0-brightgreen.svg)](build.zig.zon)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Floo is a zero-dependency tunnelling toolkit written in Zig. It can forward
traffic into private networks (forward mode) or expose local services out to a
public server (reverse mode) with Noise XX + PSK authentication.

## Highlights

- **Single static binary** – no libc or external crypto dependencies.
- **Noise XX handshake** with AES-GCM, ChaCha20-Poly1305, or AEGIS AEAD suites.
- **Forward + reverse tunnelling** with TCP + UDP support.
- **Per-service tokens** via dotted keys (`service.token = "..."`).
- **Built-in diagnostics** (`--doctor`, `--ping`) and constant-time token
  verification.
- **Proxy-aware client** – connect via SOCKS5 or HTTP CONNECT.

## Quick start

1. **Download a build** (or run `zig build -Doptimize=ReleaseFast`). Nightly
   artifacts are published at
   [github.com/YUX/floo/releases/tag/nightly](https://github.com/YUX/floo/releases/tag/nightly).
2. **Copy a template**:
   ```bash
   cp configs/floos.example.toml floos.toml
   cp configs/flooc.example.toml flooc.toml
   ```
3. **Edit secrets + services** – set `psk`, `token`, and your service entries.
4. **Start the daemons**:
   ```bash
   ./floos floos.toml   # public VPS / relay
   ./flooc flooc.toml   # home/server/client side
   ```

See `examples/` for end-to-end scenarios (media servers, databases, proxies,
load balancing, etc.).

## Configuration model

Both `flooc` and `floos` share the same TOML structure:

```toml
bind = "0.0.0.0"          # floos only
port = 8443               # floos only
server = "host:port"     # flooc only
cipher = "aes256gcm"
psk = "change-me-long-psk"
token = "change-me-token"

[services]                # Forward mode
web = "127.0.0.1:8080"
web.token = "web-only-token"

[reverse_services]        # Reverse mode
ssh = "0.0.0.0:2222"      # floos: bind; flooc: local target

[advanced]
num_tunnels = 2           # flooc only
proxy_url = "socks5://proxy:1080"  # flooc only
heartbeat_interval_seconds = 30
heartbeat_timeout_seconds = 45
```

Key points:

- Values inside `[services]` (client) describe **local listeners**; values inside
  `[services]` (server) describe **targets reachable from the server**.
- Values inside `[reverse_services]` (server) describe **public bind addresses**;
  values inside `[reverse_services]` (client) describe **local services to
  publish**.
- Set `service_name.token = "..."` to override the default token for that
  service.
- `advanced.proxy_url` accepts `socks5://` or `http://` URIs when the client must
  traverse a corporate proxy.

## Diagnostics

```bash
./floos --doctor floos.toml   # Validate server config + DNS/ports
./floos --ping floos.toml     # Probe targets defined under [services]
./flooc --doctor flooc.toml   # Validate client config + show tunnel summary
./flooc --ping                # Measure Noise handshake latency
```

Failures are reported with actionable messages (invalid cipher, weak PSK,
unreachable host, etc.).

## Performance snapshot (M1 Pro, iperf3, 4 streams)

| Scenario | Throughput |
|----------|------------|
| Raw loopback | 72 Gbps |
| Floo forward (plaintext) | 20 Gbps |
| Floo forward (AES-256-GCM) | 7.1 Gbps |
| Floo reverse (AES-256-GCM) | 5.5 Gbps |
| Rathole 0.4.9 | 13.3 Gbps |
| FRP 0.51 | 5.9 Gbps |

See `run_benchmarks.sh` for the exact harness (iperf3 + tunnel configs). Results
were captured on macOS M1; expect higher numbers on desktops/servers.

## Project layout

```
src/                  # Zig sources (client, server, protocol, UDP, proxy)
configs/              # Documented templates for flooc/floos
examples/             # Ready-made scenarios
packaging/            # Packaging helpers (deb, snap, AUR, etc.)
website/              # Project website/static assets
```

## Development

```bash
zig build test          # Run unit tests
zig fmt src/*.zig       # Format sources
./run_benchmarks.sh     # Optional throughput comparison (requires iperf3)
```

Pull requests are welcome—please include tests or diagnostics output when
changing protocol logic.

## Roadmap

- Windows support
- Compression for high-latency links
- io_uring backend (Linux)
- QUIC/DTLS transport for UDP
- Prometheus metrics / observability hooks

## License

MIT – see [LICENSE](LICENSE).
