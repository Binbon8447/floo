# Through a Corporate Proxy

flooc can dial floos via SOCKS5 or HTTP CONNECT proxies. Point `advanced.proxy_url`
to the proxy endpoint and Floo will wrap the tunnel inside that connection.

## Example workflow

1. Update `flooc.toml`
   - Set `server` to your public floos host
   - Set `proxy_url = "socks5://proxy.corp.local:1080"` (or `http://user:pass@proxy:8080`)
   - Choose a local port under `[services]` so you can run `curl https://localhost:9443`
2. Start flooc from inside the restricted network:

```bash
./flooc flooc.toml
```

3. flooc establishes a proxy tunnel, performs the Noise handshake, and exposes
   the remote service on `127.0.0.1:9443`.

4. Use your normal tooling against localhost:

```bash
curl -k https://127.0.0.1:9443/internal-status
```

The proxy never sees the decrypted application traffic—only the Floo TCP stream.
