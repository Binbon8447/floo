# Access a Cloud Database Securely

Forward PostgreSQL/MySQL/Redis traffic through Floo so the database only listens
on localhost inside your VPS.

```
Laptop (flooc) ──▶ localhost:5432 ──▶ encrypted tunnel ──▶ floos ──▶ DB :5432
```

## Files in this folder

- `floos.toml` – binds to `0.0.0.0:8443` and exposes `[services].postgres =
  "127.0.0.1:5432"`
- `flooc.toml` – listens on `127.0.0.1:5432` so local tools can connect

## Quick start

```bash
# On the VPS that hosts the database
./floos floos.toml

# On your laptop/workstation
./flooc flooc.toml
psql -h 127.0.0.1 -p 5432 -U dbuser dbname
```

## Customisation ideas

- Change `[services]` entries to point at different targets (e.g. Redis on 6379,
  MongoDB on 27017). Run multiple flooc instances if you want separate local
  ports.
- Set `num_tunnels = 2` or higher when heavy workloads open many concurrent DB
  connections.
- Increase `socket_buffer_size` for large result sets over high-latency links.
