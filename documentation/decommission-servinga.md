# Servinga Dashboard — Decommission Guide

The servinga-dashboard service (Prometheus + custom backend/frontend) has been removed from the stack.
This document explains what to disable on each client machine to stop sending metrics.

## What was running on clients

Each monitored server ran **Prometheus node_exporter** (and optionally other exporters) that exposed
metrics on port `9100`. The central Prometheus instance (`servinga-prometheus`) scraped those endpoints.

## Steps per client machine

### 1. Stop and disable node_exporter

If installed as a systemd service:

```bash
sudo systemctl stop node_exporter
sudo systemctl disable node_exporter
```

If running as a Docker container, find and remove it:

```bash
docker ps | grep node_exporter
docker stop <container_id>
docker rm <container_id>
```

### 2. Remove the firewall rule (if added)

If port 9100 was opened to the monitoring server:

```bash
# UFW example
sudo ufw delete allow from <monitoring-server-ip> to any port 9100

# iptables example
sudo iptables -D INPUT -p tcp --dport 9100 -s <monitoring-server-ip> -j ACCEPT
```

### 3. Remove any other exporters

Check for and remove other Prometheus exporters (process_exporter, blackbox_exporter, etc.)
using the same stop/disable pattern above.

### 4. Verify — no traffic to port 9090

The Prometheus server on the monitoring host (port 9090) is also gone.
After disabling exporters, verify nothing attempts to reach it:

```bash
ss -tnp | grep 9090   # should show nothing
```

## Cleanup on the monitoring server

After all clients are decommissioned, the Prometheus data volume can be deleted:

```bash
docker volume rm web-folders_servinga_prometheus_data
```

And the `servinga` PostgreSQL database can be dropped from the main DB:

```bash
docker exec -it web-folders-recipes-db-1 psql -U recipes_user -c "DROP DATABASE IF EXISTS servinga;"
docker exec -it web-folders-recipes-db-1 psql -U recipes_user -c "DROP ROLE IF EXISTS servinga_user;"
```
