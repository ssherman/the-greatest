# SSL Certificate Management Scripts

This directory contains scripts for managing SSL certificates using Let's Encrypt and Cloudflare DNS validation.

## Overview

These scripts use Docker containers to run certbot, eliminating the need to install certbot on the host system. They automatically source the Cloudflare API token from the SOPS-encrypted `.env` file.

## Scripts

### generate-certs.sh

Generates initial SSL certificates for all domains.

**Usage:**
```bash
sudo ./deployment/scripts/generate-certs.sh
```

**What it does:**
- Reads `CLOUDFLARE_API_TOKEN` from `/home/deploy/apps/the-greatest/.env`
- Pulls `certbot/dns-cloudflare` Docker image
- Generates certificates for:
  - `thegreatestmusic.org` and `www.thegreatestmusic.org`
  - `thegreatest.games` and `www.thegreatest.games`
  - `thegreatestmovies.org` and `www.thegreatestmovies.org`
- Stores certificates in `/etc/letsencrypt/live/`
- Reloads nginx to use new certificates

**Requirements:**
- Docker installed
- `.env` file exists with `CLOUDFLARE_API_TOKEN`
- Root/sudo access

### renew-certs.sh

Renews SSL certificates that are within 30 days of expiration.

**Usage:**
```bash
sudo ./deployment/scripts/renew-certs.sh
```

**What it does:**
- Reads `CLOUDFLARE_API_TOKEN` from `/home/deploy/apps/the-greatest/.env`
- Pulls `certbot/dns-cloudflare` Docker image
- Renews certificates only if needed (within 30 days of expiration)
- Reloads nginx if certificates were renewed

**Requirements:**
- Docker installed
- `.env` file exists with `CLOUDFLARE_API_TOKEN`
- Root/sudo access
- Certificates must already exist (run `generate-certs.sh` first)

## Automatic Renewal

Certificate renewal is automated via cron job, configured during server provisioning:

```bash
# Runs every Monday at 3am
0 3 * * 1 /home/deploy/apps/the-greatest/deployment/scripts/renew-certs.sh >> /var/log/cert-renewal.log 2>&1
```

This is automatically set up by the Terraform cloud-init script.

## Manual Setup

If you need to manually set up the cron job:

```bash
sudo crontab -e
```

Add:
```
0 3 * * 1 /home/deploy/apps/the-greatest/deployment/scripts/renew-certs.sh >> /var/log/cert-renewal.log 2>&1
```

## Monitoring Renewal

Check renewal logs:
```bash
sudo tail -f /var/log/cert-renewal.log
```

List current certificates and expiration dates:
```bash
sudo docker run --rm -v "/etc/letsencrypt:/etc/letsencrypt" certbot/dns-cloudflare certificates
```

## How It Works

### CLOUDFLARE_API_TOKEN Management

The scripts use SOPS-encrypted secrets:

1. `CLOUDFLARE_API_TOKEN` is stored encrypted in `secrets/.env.production`
2. GitHub Actions decrypts and deploys to `/home/deploy/apps/the-greatest/.env` during deployment
3. Scripts read the token from `.env` at runtime
4. Token is passed to Docker container via temporary file (cleaned up after use)

### Docker Container Approach

Benefits of using Docker:
- No certbot installation required on host
- Consistent certbot version across all environments
- Isolated from system dependencies
- Easy to update (just pull new image)
- Works with SOPS secrets workflow

### Security Considerations

- Temporary credentials file created with `chmod 600`
- Credentials file deleted automatically via `trap` on script exit
- `.env` file has `chmod 600` permissions (set by deployment script)
- Cloudflare API token never logged or echoed
- Docker runs with read-only mount of credentials file

## Troubleshooting

### Script fails with "CLOUDFLARE_API_TOKEN not found"

The `.env` file doesn't exist or doesn't contain the token.

**Fix:**
1. Ensure deployment has run successfully (GitHub Actions or manual)
2. Check file exists: `ls -la /home/deploy/apps/the-greatest/.env`
3. Check token present: `sudo grep CLOUDFLARE_API_TOKEN /home/deploy/apps/the-greatest/.env`

### Certificate generation fails with DNS validation error

Cloudflare API token may be invalid or lack permissions.

**Fix:**
1. Verify token in Cloudflare dashboard
2. Ensure token has "Zone:DNS:Edit" permissions for all zones
3. Re-encrypt with correct token:
   ```bash
   SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
     sops secrets/.env.production
   ```

### Docker pull fails

Network issue or Docker not running.

**Fix:**
```bash
sudo systemctl status docker
sudo systemctl start docker
sudo docker pull certbot/dns-cloudflare
```

### Nginx reload fails

Nginx container may not be running.

**Fix:**
```bash
cd /home/deploy/apps/the-greatest
docker compose -f docker-compose.prod.yml ps nginx
docker compose -f docker-compose.prod.yml restart nginx
```

## Testing

Test certificate generation (dry run):
```bash
sudo docker run --rm \
  -v "/etc/letsencrypt:/etc/letsencrypt" \
  -v "/tmp/cloudflare.ini:/cloudflare.ini:ro" \
  certbot/dns-cloudflare certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /cloudflare.ini \
  -d "thegreatestmusic.org" \
  --dry-run
```

Test renewal (dry run):
```bash
sudo docker run --rm \
  -v "/etc/letsencrypt:/etc/letsencrypt" \
  -v "/tmp/cloudflare.ini:/cloudflare.ini:ro" \
  certbot/dns-cloudflare renew \
  --dry-run
```

## Related Documentation

- [MANUAL_DEPLOY.md](../MANUAL_DEPLOY.md) - Manual deployment instructions
- [SECRETS.md](../SECRETS.md) - SOPS secrets management
- [docs/specs/049-sops-secrets-management.md](../../docs/specs/049-sops-secrets-management.md) - SOPS implementation details
