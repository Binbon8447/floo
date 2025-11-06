# Access Cloud Database Securely

## What This Does

Securely access your cloud database (PostgreSQL, MySQL, Redis, etc.) from your local machine through an encrypted tunnel.

**Perfect for:** Remote database work, avoiding public database exposure, encrypting database connections.

## The Setup

```
Your Laptop                      Cloud Server (VPS)
┌──────────────────┐            ┌─────────────────────┐
│ App/Tool         │            │                     │
│ ↓                │            │ Database            │
│ localhost:5432 ──┼─Encrypted──┤ → localhost:5432    │
│ (flooc listens)  │   Tunnel   │   (PostgreSQL)      │
└──────────────────┘            └─────────────────────┘
```

This is **forward tunneling** (traditional mode) - opposite of reverse mode!

## Step-by-Step Setup

### 1. On Cloud Server (Where Database Runs)

**File:** `floos.toml`

```toml
port = 8443
host = "0.0.0.0"
cipher = "aegis128l"
psk = "YOUR_PSK"
default_token = "YOUR_TOKEN"

[server.services.database]
id = 1
transport = "tcp"              # Forward mode (default, can omit mode="forward")
target_host = "127.0.0.1"     # Server connects to this
target_port = 5432             # PostgreSQL port (change for MySQL: 3306)
```

**Start:**
```bash
./floos floos.toml
```

### 2. On Your Laptop

**File:** `flooc.toml`

```toml
local_host = "127.0.0.1"      # Only accessible from your laptop
local_port = 5432              # Port your app connects to
remote_host = "YOUR_CLOUD_IP"  # Cloud server IP
remote_port = 8443
target_host = "127.0.0.1"      # Informational (server uses its own config)
target_port = 5432
cipher = "aegis128l"
psk = "YOUR_PSK"
default_token = "YOUR_TOKEN"
service_id = 1
num_tunnels = 2                # Load balancing
```

**Start:**
```bash
./flooc flooc.toml
```

### 3. Connect to Database

```bash
# PostgreSQL
psql -h localhost -p 5432 -U dbuser mydatabase

# MySQL
mysql -h 127.0.0.1 -P 5432 -u dbuser mydatabase

# Any tool that supports localhost connection!
```

## How Forward Mode Works

1. **flooc** on your laptop listens on localhost:5432
2. You connect to localhost:5432 with your database tool
3. **flooc** forwards through encrypted tunnel to **floos**
4. **floos** connects to localhost:5432 on cloud server (database)
5. Data flows: Your App → flooc → Tunnel → floos → Database

**Key difference from reverse mode:**
- Forward: Client listens, server connects to target
- Reverse: Server listens, client connects to target

## Use Cases

- **Database access:** PostgreSQL, MySQL, MongoDB, Redis
- **Internal APIs:** Access company APIs through bastion host
- **Development:** Connect to staging/production databases safely
- **Security:** Encrypt connections to databases without TLS

## Troubleshooting

### Connection Refused

```bash
# Test if database is accessible from server:
ssh user@YOUR_CLOUD_IP
curl localhost:5432  # or psql, mysql, etc.
```

If database not accessible from server:
- Check database is running
- Check database binds to 127.0.0.1 or 0.0.0.0
- Check firewall on cloud server

### Can't Connect to localhost:5432

```bash
# Check if flooc is listening:
lsof -i :5432

# Should show flooc process
```

If not listening:
- Check flooc is running
- Verify `local_port = 5432` in config
- Try different port if 5432 is occupied

## Security Notes

- ✅ **Database never exposed:** Database only listens on localhost
- ✅ **Encrypted transport:** All database traffic encrypted
- ✅ **No public database ports:** Firewall can block database port
- ✅ **Access control:** Token authentication required

## Performance

- **Latency:** +1-2ms overhead from encryption
- **Throughput:** Limited by your internet speed, not Floo (29 Gbps capable)
- **Concurrent connections:** Multiple database connections supported

## Advanced: Multiple Databases

Access both PostgreSQL and Redis:

**Server:**
```toml
[server.services.postgres]
id = 1
target_port = 5432

[server.services.redis]
id = 2
target_port = 6379
```

**Client:** Run TWO flooc instances:
```bash
# Terminal 1:
./flooc flooc-postgres.toml  # service_id = 1, local_port = 5432

# Terminal 2:
./flooc flooc-redis.toml     # service_id = 2, local_port = 6379
```

Or use multi-service mode (see flooc.toml.example in root).
