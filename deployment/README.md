# The Greatest - Production Deployment Guide

This guide covers deploying The Greatest Rails application to production using Docker Compose with nginx, SSL certificates, and multi-domain support.

## Architecture Overview

The production deployment consists of:
- **web**: Rails application server (Thruster + Puma)
- **worker**: Sidekiq background job processor
- **nginx**: Reverse proxy with SSL termination
- **redis**: In-memory data store for Sidekiq and caching
- **External Services**: PostgreSQL and OpenSearch (hosted separately)

## Prerequisites

- Linode instance provisioned via Terraform (see `deployment/terraform/`)
- External PostgreSQL database
- External OpenSearch instance
- Cloudflare API token with DNS edit permissions
- GitHub Container Registry access
- Domain DNS configured to point to server IP

## Quick Start

### 1. Initial Server Setup

SSH into your server:
```bash
ssh deploy@your-server-ip
cd /home/deploy/apps/the-greatest
```

### 2. Configure Environment Variables

Create `.env` file with required variables (see `ENV.md`):
```bash
cp .env.example .env
nano .env
```

### 3. Generate SSL Certificates

Run the certificate generation script:
```bash
export CLOUDFLARE_API_TOKEN=your_token_here
sudo ./deployment/scripts/generate-certs.sh
```

This generates certificates for:
- thegreatestmusic.org + www.thegreatestmusic.org
- thegreatest.games + www.thegreatest.games
- thegreatestmovies.org + www.thegreatestmovies.org

### 4. Start Services

Launch all containers:
```bash
docker compose -f docker-compose.prod.yml up -d
```

### 5. Verify Deployment

Check service status:
```bash
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs -f
```

Test each domain:
```bash
curl https://thegreatestmusic.org
curl https://thegreatest.games
curl https://thegreatestmovies.org
```

## Service Details

### Web Service
- **Image**: ghcr.io/ssherman/the-greatest:latest
- **Port**: 80 (internal, proxied by nginx)
- **Command**: `./bin/rails server`
- **Health Check**: HTTP GET /up

### Worker Service
- **Image**: ghcr.io/ssherman/the-greatest:latest
- **Command**: `bundle exec sidekiq`
- **Health Check**: Process check for sidekiq

### Nginx Service
- **Build**: Custom image with bad-bot-blocker
- **Ports**: 80, 443
- **SSL**: Let's Encrypt certificates via Cloudflare DNS
- **Templating**: Uses nginx's built-in template system with environment variable substitution
- **Features**:
  - SSL termination for 6 domain variants
  - www to non-www redirects
  - Firebase Auth proxy for /__/auth/* paths
  - Bad bot blocking
  - Security headers

### Redis Service
- **Image**: redis:7-alpine
- **Port**: 6379 (internal)
- **Persistence**: AOF enabled

## SSL Certificate Management

### Certificate Locations
Certificates are stored in the `letsencrypt-certs` volume:
```
/etc/letsencrypt/live/thegreatestmusic.org/
  ├── fullchain.pem
  └── privkey.pem
/etc/letsencrypt/live/thegreatest.games/
  ├── fullchain.pem
  └── privkey.pem
/etc/letsencrypt/live/thegreatestmovies.org/
  ├── fullchain.pem
  └── privkey.pem
```

### Certificate Renewal

Set up a cron job for automatic renewal:
```bash
sudo crontab -e
```

Add:
```
0 3 * * 1 CLOUDFLARE_API_TOKEN=your_token /home/deploy/apps/the-greatest/deployment/scripts/renew-certs.sh >> /var/log/cert-renewal.log 2>&1
```

Or run manually:
```bash
export CLOUDFLARE_API_TOKEN=your_token_here
sudo ./deployment/scripts/renew-certs.sh
```

## Multi-Domain Configuration

The application serves 3 primary domains, each with www variant:

### thegreatestmusic.org
- Canonical: https://thegreatestmusic.org
- Redirect: www.thegreatestmusic.org → thegreatestmusic.org
- Firebase Auth: thegreatestmusic-org.firebaseapp.com

### thegreatest.games
- Canonical: https://thegreatest.games
- Redirect: www.thegreatest.games → thegreatest.games
- Firebase Auth: thegreatest-games.firebaseapp.com

### thegreatestmovies.org
- Canonical: https://thegreatestmovies.org
- Redirect: www.thegreatestmovies.org → thegreatestmovies.org
- Firebase Auth: thegreatestmovies-org.firebaseapp.com

## Log Management

All services use log rotation to prevent disk space issues:
- **Driver**: json-file
- **Max Size**: 10MB per file
- **Max Files**: 3 files per service
- **Total**: 30MB maximum per service

View logs:
```bash
docker compose -f docker-compose.prod.yml logs -f web
docker compose -f docker-compose.prod.yml logs -f worker
docker compose -f docker-compose.prod.yml logs -f nginx
```

## Continuous Deployment

GitHub Actions automatically deploys on push to main:

1. Build workflow builds and pushes Docker image
2. Deploy workflow SSHs to server and runs:
   ```bash
   cd /home/deploy/apps/the-greatest
   git pull
   docker compose -f docker-compose.prod.yml pull
   docker compose -f docker-compose.prod.yml up -d
   docker system prune -f
   ```

## Database Migrations

Migrations run automatically via the Docker entrypoint when the web container starts.

To run manually:
```bash
docker compose -f docker-compose.prod.yml exec web bin/rails db:migrate
```

## Maintenance Commands

### Restart All Services
```bash
docker compose -f docker-compose.prod.yml restart
```

### Restart Individual Service
```bash
docker compose -f docker-compose.prod.yml restart web
docker compose -f docker-compose.prod.yml restart worker
docker compose -f docker-compose.prod.yml restart nginx
```

### View Service Status
```bash
docker compose -f docker-compose.prod.yml ps
```

### Clean Up Old Resources
```bash
docker system prune -af
docker volume prune -f
```

### Access Rails Console
```bash
docker compose -f docker-compose.prod.yml exec web bin/rails console
```

### Check Sidekiq Status
```bash
docker compose -f docker-compose.prod.yml exec worker ps aux | grep sidekiq
```

## Monitoring

### Health Checks
All services have health checks:
```bash
docker inspect the-greatest-web | grep -A 10 Health
docker inspect the-greatest-worker | grep -A 10 Health
docker inspect the-greatest-nginx | grep -A 10 Health
```

### Resource Usage
```bash
docker stats
```

### Disk Space
```bash
df -h
docker system df
```

## Security

### Origin Lockdown

The origin serves a page only when all three of these hold (design:
`docs/superpowers/specs/2026-09-14-origin-lockdown-design.md`):

1. **The connection comes from a Cloudflare IP range.** `deployment/nginx/bin/generate-cloudflare-snippets.sh`
   runs at image build and turns Cloudflare's published list into a `geo` map on
   `$realip_remote_addr`; every named server block returns 444 (connection closed, no
   response) when it says no. Every deploy rebuilds the image, so the list refreshes itself;
   a bad fetch fails the build instead of shipping a permissive list.
2. **The request names one of our hostnames.** A `default_server` on port 80 returns 444 for
   any other `Host`; a `default_server` on 443 uses `ssl_reject_handshake`, so an unknown or
   missing SNI never even sees a certificate. Port 80 only redirects — it no longer proxies
   to Rails on `X-Forwarded-Proto: https`.
3. **Cloudflare presented its origin-pull client certificate** (Authenticated Origin Pulls,
   `ssl_client_certificate` + `ssl_verify_client` in `snippets/ssl-params.conf`, CA in
   `deployment/nginx/certs/`, expires 2029-11-01). The matching Cloudflare setting is
   `tls_client_auth: on`, managed by `cfrules` in the private `the-greatest-cloudflare` repo.
   Rolling out in stages: nginx runs `ssl_verify_client optional` (verifies a certificate when
   one is presented, still serves without one) until production logs show `verify=SUCCESS` on
   every port-443 request; the switch to `on` is what makes this condition mandatory.

The same Cloudflare list feeds `real_ip_header CF-Connecting-IP`, so nginx's `$remote_addr`,
the access log, the bot-blocker's per-IP limits, and Rails' `request.remote_ip` are the
visitor's address, not the Cloudflare edge's. The access log carries `cf=<peer> verify=<AOP result>`.

**Accepted residual:** Cloudflare's shared origin-pull certificate proves "from Cloudflare's
network", not "from our zones". An attacker with a Cloudflare *Enterprise* account could use
Host-header override through their own zone. Spec §9 lists the two ways to close that later.

**Verify after any nginx change:** `deployment/scripts/verify-origin-lockdown.sh` from a
machine outside Cloudflare. Locally, `deployment/nginx/test/local-lockdown-test.sh` exercises
the whole matrix against a throwaway container.

### Everything Else

- All secrets managed via environment variables (SOPS/age)
- SSL certificates with strong ciphers (TLS 1.2+), HSTS enabled
- Bad bot blocking active
- UFW firewall (22, 80, 443) and fail2ban for SSH — note that Docker-published ports do not
  obey UFW, which is why the origin lockdown lives in nginx rather than the host firewall
- Non-root user for Rails processes

## Troubleshooting

See `TROUBLESHOOTING.md` for common issues and solutions.

## Rollback

See `ROLLBACK.md` for rollback procedures.

## Related Documentation

- `ENV.md` - Environment variable reference
- `MANUAL_DEPLOY.md` - Manual deployment steps
- `TROUBLESHOOTING.md` - Common issues
- `ROLLBACK.md` - Rollback procedures
