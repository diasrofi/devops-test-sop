# DevOps test stand

Production-like stand for a DevOps test assignment.

## Architecture

The stand contains three Docker Compose services:

- nginx
- app
- postgres

Only these ports are published outside:

- 22/tcp for SSH
- 80/tcp for HTTP redirect
- 443/tcp for HTTPS

The app and postgres services do not publish ports to the host. They are available only inside the Docker network.

## Project structure

- docker-compose.yml
- .env.example
- nginx/app.conf
- html/index.html
- app/Dockerfile
- app/go.mod
- app/go.sum
- app/main.go
- scripts/backup-db.sh

## Server requirements

Tested on Ubuntu 24.04 LTS in a Multipass VM.

Recommended VM:

- 2 CPU
- 2 GB RAM
- 12 GB disk

## Install Docker

Run on a clean Ubuntu server:

    sudo apt-get update
    sudo apt-get install -y ca-certificates curl git openssl ufw
    curl -fsSL https://get.docker.com | sudo sh
    sudo systemctl enable --now docker

## Deploy

Clone the repository to /opt/app:

    sudo mkdir -p /opt/app
    sudo chown -R "$USER:$USER" /opt/app
    git clone <REPO_URL> /opt/app
    cd /opt/app

Create the .env file:

    cp .env.example .env
    POSTGRES_PASSWORD="$(openssl rand -base64 24 | tr -d "\n")"
    sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" .env
    chmod 600 .env

Create a self-signed SSL certificate:

    mkdir -p ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ssl/privkey.pem -out ssl/fullchain.pem -subj "/CN=devtest.local"
    chmod 600 ssl/privkey.pem

Start the stand:

    sudo docker compose up -d --build
    sudo docker compose ps

## Check

Health endpoint:

    curl -k https://localhost/api/health

API endpoint:

    curl -k https://localhost/api/hello

Expected result:

    ok
    {"message":"hello","time":"..."}

## Firewall

Firewall rules:

    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow 22/tcp
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw --force enable
    sudo ufw status verbose

Only 22, 80 and 443 should be open.

## SSH hardening

Config file:

    /etc/ssh/sshd_config.d/99-devops-hardening.conf

Content:

    PasswordAuthentication no
    PermitRootLogin no
    PubkeyAuthentication yes

Check:

    sudo sshd -T | grep -E "^(passwordauthentication|permitrootlogin|pubkeyauthentication) "

Expected result:

    permitrootlogin no
    pubkeyauthentication yes
    passwordauthentication no

Important: on a real VPS, add an SSH public key before disabling password login.

## Backups

Backup script:

    scripts/backup-db.sh

Install it:

    sudo cp scripts/backup-db.sh /usr/local/bin/backup-db.sh
    sudo chmod 755 /usr/local/bin/backup-db.sh

Run backup manually:

    sudo /usr/local/bin/backup-db.sh
    sudo ls -lh /var/backups/app/

The script runs pg_dump from the app-postgres container, compresses the dump with gzip and removes backups older than 7 days.

Example cron entry for daily backups at 03:00:

    0 3 * * * /usr/local/bin/backup-db.sh >> /var/log/backup-db.log 2>&1

## Restore from backup

List backups:

    sudo ls -lh /var/backups/app/

Restore:

    gunzip -c /var/backups/app/db-YYYYMMDD-HHMMSS.sql.gz | sudo docker exec -i app-postgres psql -U app app

## Reboot check

Reboot the server:

    sudo reboot

After reboot:

    cd /opt/app
    sudo docker compose ps
    curl -k https://localhost/api/health
    curl -k https://localhost/api/hello
    sudo /usr/local/bin/backup-db.sh

On my test VM after reboot:

- Docker service was enabled and active
- app was Up
- app-nginx was Up
- app-postgres was Up and healthy
- /api/health returned ok
- /api/hello returned JSON
- backup successfully created a second .sql.gz file
- firewall was active
- SSH password login was disabled
- root SSH login was disabled

## Why this design

Postgres has no published host port because only the app needs database access.

The app has no published host port because all external traffic must go through nginx.

restart: unless-stopped is used so containers start automatically after reboot.

depends_on with service_healthy is used so the app waits until Postgres is ready.

A self-signed SSL certificate is used because the VM has no public domain for Let us Encrypt.


## Logs

Show logs for all services:

    cd /opt/app
    sudo docker compose logs

Show nginx logs:

    sudo docker compose logs nginx

Show app logs:

    sudo docker compose logs app

Show postgres logs:

    sudo docker compose logs postgres

## Troubleshooting

### /api/hello returns 502

Check container status:

    cd /opt/app
    sudo docker compose ps

Check app and nginx logs:

    sudo docker compose logs app
    sudo docker compose logs nginx

Common reasons:

- app container is not running
- Postgres is not healthy yet
- DATABASE_URL is wrong
- nginx proxy_pass points to the wrong service name or port

### Backup creates an empty file or fails

Check that /opt/app/.env exists:

    sudo cat /opt/app/.env

Check Postgres container:

    cd /opt/app
    sudo docker compose ps postgres

Run backup manually:

    sudo /usr/local/bin/backup-db.sh

The backup script uses set -euo pipefail and checks required variables, so it stops on errors instead of silently creating a broken backup.

### Containers are not running after reboot

Check Docker:

    sudo systemctl is-enabled docker
    sudo systemctl is-active docker

Docker should be enabled:

    sudo systemctl enable --now docker

Check containers:

    cd /opt/app
    sudo docker compose ps

The services use restart: unless-stopped, so they start again after Docker starts.

## What I would add with more time

- GitHub Actions for docker compose config, nginx config validation and shellcheck
- fail2ban for SSH brute-force protection
- nginx rate limiting for /api/
- automatic backup restore test
- monitoring with Netdata or Prometheus/node-exporter
- Ansible playbook for fully automated deployment
