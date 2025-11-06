# Floo Configuration Examples

This directory contains real-world configuration examples for common use cases.

## Available Examples

### 🏠 [expose-home-server](expose-home-server/)
**Use case:** Access your home media server (Emby, Plex) from anywhere
**Mode:** Reverse tunneling (single service)
**Setup:** flooc on home machine, floos on public server

### 🔐 [expose-multiple-services](expose-multiple-services/)
**Use case:** Expose both media server AND SSH through one tunnel
**Mode:** Reverse tunneling (multiple services)
**Setup:** One flooc serves multiple services

### 💾 [access-cloud-database](access-cloud-database/)
**Use case:** Securely access cloud database from local machine
**Mode:** Forward tunneling (traditional)
**Setup:** Connect to remote services through encrypted tunnel

### 🏢 [through-corporate-proxy](through-corporate-proxy/)
**Use case:** Connect through corporate SOCKS5/HTTP proxy
**Mode:** Forward with proxy
**Setup:** Bypass firewall restrictions

### ⚡ [multi-client-loadbalancing](multi-client-loadbalancing/)
**Use case:** High-throughput scenarios with load balancing
**Mode:** Multiple parallel tunnels
**Setup:** Maximize bandwidth utilization

## Quick Start

1. Choose the example that matches your use case
2. Copy the config files
3. Update `YOUR_SERVER_IP` and passwords
4. Run `--doctor` to validate setup
5. Start floos and flooc

## Need Help?

Run diagnostics before starting:
```bash
./floos --doctor floos.toml
./flooc --doctor flooc.toml
```
