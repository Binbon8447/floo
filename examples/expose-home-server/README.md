# Expose Home Server (Emby/Plex/Jellyfin)

Access your home media server from anywhere using reverse tunneling.

**Setup:** flooc on home → floos on public server → Users access server
**No SSH tunnel needed!**

## Quick Start
1. Edit configs: Replace `YOUR_SERVER_IP` and passwords
2. RPI: `./floos floos.toml`
3. Home: `./flooc flooc.toml`  
4. Access: `http://YOUR_SERVER_IP:8096`
