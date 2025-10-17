# Manual Deployment Instructions

This guide covers manual deployment of The Greatest application to production without relying on GitHub Actions CI/CD.

## Prerequisites

- Root or sudo access to production server
- Git installed on server
- Docker and Docker Compose installed
- External PostgreSQL database accessible
- External OpenSearch instance accessible
- Cloudflare API token for SSL certificates
- GitHub Container Registry credentials

## Step-by-Step Deployment

### 1. Server Preparation

SSH into your production server:
```bash
ssh root@your-server-ip
```

Create deploy user (if not already created):
```bash
useradd -m -s /bin/bash deploy
usermod -aG sudo deploy
usermod -aG docker deploy
```

Switch to deploy user:
```bash
su - deploy
```

### 2. Install Dependencies

Update system packages:
```bash
sudo apt-get update
sudo apt-get upgrade -y
```

Install required packages:
```bash
sudo apt-get install -y \
    git \
    docker.io \
    docker-compose \
    fail2ban \
    ufw
```

Note: certbot is no longer required on the host system. The scripts use the `certbot/dns-cloudflare` Docker image instead.

Enable and start Docker:
```bash
sudo systemctl enable docker
sudo systemctl start docker
```

### 3. Configure Firewall

Set up UFW firewall:
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https
sudo ufw enable
```

Verify firewall status:
```bash
sudo ufw status
```

### 4. Configure Fail2ban

Enable fail2ban for SSH protection:
```bash
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

### 5. Clone Repository

Create application directory:
```bash
mkdir -p /home/deploy/apps
cd /home/deploy/apps
```

Clone repository:
```bash
git clone https://github.com/ssherman/the-greatest.git
cd the-greatest
```

### 6. Configure Environment

Create `.env` file:
```bash
nano .env
```

Add required environment variables (see ENV.md for complete reference):
```bash
# Rails
RAILS_ENV=production
RAILS_MASTER_KEY=your_master_key_here
SECRET_KEY_BASE=your_secret_key_base_here

# Database
POSTGRES_HOST=your_postgres_host
POSTGRES_PORT=5432
POSTGRES_DATABASE=the_greatest_production
POSTGRES_USER=the_greatest
POSTGRES_PASSWORD=your_postgres_password

# Redis
REDIS_URL=redis://redis:6379/1

# OpenSearch
OPENSEARCH_URL=https://your-opensearch-host:9200

# Nginx
WEB_HOST=web
WEB_PORT=80
CERT_PATH=/etc/letsencrypt/live
KEY_PATH=/etc/letsencrypt/live
```

Save and exit (Ctrl+X, Y, Enter).

### 7. Generate SSL Certificates

The certificate generation script now uses Docker and automatically pulls the Cloudflare API token from the `.env` file (managed via SOPS).

Run certificate generation script:
```bash
sudo ./deployment/scripts/generate-certs.sh
```

This will:
- Read `CLOUDFLARE_API_TOKEN` from `.env` file
- Pull `certbot/dns-cloudflare` Docker image
- Generate certificates for all domains using Cloudflare DNS validation
- Store certificates in `/etc/letsencrypt/live/`
- Reload nginx

Verify certificates:
```bash
sudo ls -l /etc/letsencrypt/live/
```

Note: The script no longer requires manual installation of certbot or passing environment variables.

### 8. Login to GitHub Container Registry

Authenticate with GitHub Container Registry:
```bash
echo $GITHUB_TOKEN | docker login ghcr.io -u $GITHUB_USERNAME --password-stdin
```

Or use a personal access token:
```bash
docker login ghcr.io
```

### 9. Build Nginx Image

Build the custom nginx image:
```bash
docker build -t the-greatest-nginx:latest ./deployment/nginx/
```

### 10. Pull Application Image

Pull the latest Rails application image:
```bash
docker pull ghcr.io/ssherman/the-greatest:latest
```

Or build locally:
```bash
docker build -t ghcr.io/ssherman/the-greatest:latest ./web-app/
```

### 11. Start Services

Start all services:
```bash
docker compose -f docker-compose.prod.yml up -d
```

Monitor startup:
```bash
docker compose -f docker-compose.prod.yml logs -f
```

Wait for all services to be healthy (Ctrl+C to stop logs).

### 12. Verify Services

Check service status:
```bash
docker compose -f docker-compose.prod.yml ps
```

All services should show "Up" and "healthy".

Test health endpoints:
```bash
curl http://localhost/up
```

### 13. Run Database Setup

If this is a fresh deployment, run database setup:
```bash
docker compose -f docker-compose.prod.yml exec web bin/rails db:create
docker compose -f docker-compose.prod.yml exec web bin/rails db:migrate
docker compose -f docker-compose.prod.yml exec web bin/rails db:seed
```

For existing database, migrations run automatically via Docker entrypoint.

### 14. Test Domain Access

Test each domain with curl:
```bash
curl -I https://thegreatestmusic.org
curl -I https://thegreatest.games
curl -I https://thegreatestmovies.org
```

Should return `200 OK` or `302 Found`.

Test www redirects:
```bash
curl -I https://www.thegreatestmusic.org
curl -I https://www.thegreatest.games
curl -I https://www.thegreatestmovies.org
```

Should return `301 Moved Permanently` to non-www version.

### 15. Set Up Certificate Renewal

Create cron job for certificate renewal (runs weekly on Monday at 3am):
```bash
sudo crontab -e
```

Add:
```
0 3 * * 1 /home/deploy/apps/the-greatest/deployment/scripts/renew-certs.sh >> /var/log/cert-renewal.log 2>&1
```

Save and exit.

The renewal script:
- Automatically reads `CLOUDFLARE_API_TOKEN` from `/home/deploy/apps/the-greatest/.env`
- Uses Docker to run certbot (no system installation required)
- Only renews certificates within 30 days of expiration
- Reloads nginx after successful renewal

Test the renewal manually:
```bash
sudo /home/deploy/apps/the-greatest/deployment/scripts/renew-certs.sh
```

### 16. Configure Auto-Start

Ensure services restart on reboot:
```bash
docker compose -f /home/deploy/apps/the-greatest/docker-compose.prod.yml up -d
```

Docker's restart policy (`restart: unless-stopped`) will handle automatic restart.

## Updating the Application

### Pull Latest Code

```bash
cd /home/deploy/apps/the-greatest
git pull origin main
```

### Pull Latest Images

```bash
docker compose -f docker-compose.prod.yml pull
```

### Restart Services

```bash
docker compose -f docker-compose.prod.yml up -d
```

Docker Compose will recreate only the changed services.

### Run Migrations

If needed (usually automatic via entrypoint):
```bash
docker compose -f docker-compose.prod.yml exec web bin/rails db:migrate
```

### Clean Up

Remove old images and containers:
```bash
docker system prune -af
```

## Maintenance Tasks

### View Logs

```bash
docker compose -f docker-compose.prod.yml logs -f web
docker compose -f docker-compose.prod.yml logs -f worker
docker compose -f docker-compose.prod.yml logs -f nginx
```

### Restart Individual Service

```bash
docker compose -f docker-compose.prod.yml restart web
docker compose -f docker-compose.prod.yml restart worker
docker compose -f docker-compose.prod.yml restart nginx
```

### Access Rails Console

```bash
docker compose -f docker-compose.prod.yml exec web bin/rails console
```

### Run Rake Tasks

```bash
docker compose -f docker-compose.prod.yml exec web bin/rails task:name
```

### Check Resource Usage

```bash
docker stats
df -h
free -h
```

### Backup Database

```bash
docker compose -f docker-compose.prod.yml exec web bin/rails db:dump
```

Or directly from PostgreSQL:
```bash
pg_dump -h $POSTGRES_HOST -U $POSTGRES_USER $POSTGRES_DATABASE > backup.sql
```

## Troubleshooting

If deployment fails, see:
- `TROUBLESHOOTING.md` - Common issues and solutions
- `ROLLBACK.md` - Rollback procedures

## Security Checklist

- [ ] Firewall configured (UFW)
- [ ] Fail2ban enabled
- [ ] SSL certificates installed and valid
- [ ] Strong passwords for database
- [ ] Environment variables secured
- [ ] Non-root user for deployment
- [ ] SSH key authentication (disable password auth)
- [ ] Regular security updates scheduled

## Monitoring Setup

Consider setting up monitoring:
- Application performance monitoring (APM)
- Log aggregation
- Uptime monitoring
- Disk space alerts
- SSL certificate expiration alerts

## Next Steps

After successful manual deployment:
1. Test all functionality thoroughly
2. Monitor logs for errors
3. Set up automated backups
4. Configure monitoring and alerts
5. Document any custom configurations
6. Consider setting up CI/CD for future deployments
