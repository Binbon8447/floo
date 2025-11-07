# Floo Examples

Each subdirectory provides ready-to-run `floos.toml`/`flooc.toml` pairs for a
specific deployment pattern.

| Example | Mode | Highlights |
|---------|------|------------|
| [`access-cloud-database/`](access-cloud-database/) | Forward | Keep databases private while admins connect over localhost |
| [`expose-home-server/`](expose-home-server/) | Reverse | Publish Jellyfin/Emby from home through a VPS |
| [`expose-multiple-services/`](expose-multiple-services/) | Reverse | Serve media + SSH simultaneously with per-service tokens |
| [`multi-client-loadbalancing/`](multi-client-loadbalancing/) | Reverse | Run multiple flooc instances for round-robin load sharing |
| [`reverse-forwarding-emby/`](reverse-forwarding-emby/) | Reverse | Minimal example focused on media streaming | 
| [`through-corporate-proxy/`](through-corporate-proxy/) | Forward | Dial through SOCKS5/HTTP proxies while keeping traffic encrypted |

All configs follow the same structure implemented in `src/config.zig`. Copy the
pair that matches your use case, update secrets and IPs, then run `./floos` on
the server and `./flooc` on the client. Use `--doctor` before going live.
