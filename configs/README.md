# Configuration Templates

The `configs/` directory contains ready-to-use TOML templates for both the Floo
server (`floos`) and client (`flooc`). Each template follows the exact format
implemented in `src/config.zig`:

1. **Core tunnel settings** – listener/bind information plus cipher, PSK, token
2. **Services** – what to forward (server-side) or expose/listen for (client-side)
3. **Advanced tuning** – optional knobs for TCP, UDP, heartbeats, proxies, etc.

## Available templates

| File | Description |
|------|-------------|
| `floos.example.toml` | Comprehensive server config with comments on every option |
| `flooc.example.toml` | Comprehensive client config covering forward + reverse setups |
| `floos.minimal.toml` | Minimal server config for quick smoke tests |
| `flooc.minimal.toml` | Minimal client config for exposing one local service |

## Using a template

```bash
cp configs/floos.example.toml floos.toml
cp configs/flooc.example.toml flooc.toml
```

Update **at least** the `psk`, `token`, and any hostnames/IPs. The server must be
started before the client:

```bash
./floos floos.toml   # on your VPS/cloud host
./flooc flooc.toml   # on your laptop/home server
```

## Per-service overrides

Inside the `[services]` or `[reverse_services]` sections you can override
service-specific settings using dotted keys:

```toml
[services]
ssh = "127.0.0.1:2222"
ssh.token = "ssh-only-token"
```

Tokens fall back to the global `token` when no override is provided. Reverse
services behave the same way.

## More examples

For end-to-end walkthroughs (home media, database access, proxies, etc.), check
[`examples/`](../examples/).
