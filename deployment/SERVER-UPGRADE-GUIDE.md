# Server Upgrade Guide

Step-by-step instructions for upgrading or rebuilding the Linode server using Terraform.

## Prerequisites

- Terraform installed locally
- SSH access configured
- Access to Cloudflare dashboard
- Access to GitHub Actions (or SSH to server)

## Steps

### 1. Make Terraform Changes

Edit the desired variables in `deployment/terraform/variables.tf`:

```bash
cd deployment/terraform
```

Common changes:
- `instance_type` — server size (e.g., `g6-standard-4`)
- `instance_region` — datacenter location

### 2. Preview and Apply

```bash
terraform plan      # Preview what will change
terraform apply     # Apply changes (confirm when prompted)
```

Note the new server IP from the output.

### 3. Wait for Cloud-Init

Cloud-init runs automatically on new servers. SSH in and monitor:

```bash
ssh deploy@<NEW_IP>

# Watch progress
sudo tail -f /var/log/cloud-init-output.log

# Or wait for completion
cloud-init status --wait
```

Cloud-init takes ~2-3 minutes and will:
- Install Docker
- Clone the repo to `/home/deploy/apps/the-greatest`
- Create the deploy user
- Set up firewall and fail2ban

### 4. Update Cloudflare DNS

**This is manual until we automate it.**

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com)
2. For each domain (thegreatestmusic.org, thegreatest.games, thegreatestmovies.org):
   - Select the domain → DNS → Records
   - Update the A record for `@` (root) to the new IP
   - Update the A record for `www` to the new IP
3. Changes propagate within seconds if using Cloudflare proxy (orange cloud)

### 5. Generate SSL Certificates

On the server, generate certificates for all domains:

```bash
ssh deploy@<NEW_IP>
cd /home/deploy/apps/the-greatest

# First, decrypt secrets to get CLOUDFLARE_API_TOKEN
# (Requires age key - see "Decrypting Secrets" below)

# Generate certs (requires sudo for /etc/letsencrypt)
sudo deployment/scripts/generate-certs.sh
```

### 6. Deploy the Application

**Option A: Trigger GitHub Actions (recommended)**

1. Go to GitHub → Actions → "Deploy to Production"
2. Click "Run workflow" → "Run workflow"

This will:
- Pull latest code
- Decrypt secrets to `.env`
- Pull Docker images
- Start all containers

**Option B: Manual deploy on server**

```bash
ssh deploy@<NEW_IP>
cd /home/deploy/apps/the-greatest

# Decrypt secrets (see below)
# Then start containers:
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
```

### 7. Verify

```bash
# Check all containers are running
docker ps

# Should show: redis, web, worker, nginx (all healthy)

# Test the site
curl -I https://thegreatestmusic.org
```

---

## Decrypting Secrets

Secrets are encrypted with SOPS/age. To decrypt manually:

```bash
# Write your age key to the expected location
mkdir -p ~/.config/sops/age
echo "AGE-SECRET-KEY-1..." > ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# Decrypt
cd /home/deploy/apps/the-greatest
sops -d secrets/.env.production > .env
chmod 600 .env

# Clean up age key
rm ~/.config/sops/age/keys.txt
```

---

## Troubleshooting

### Nginx won't start (SSL cert errors)
Certs don't exist yet. Run `generate-certs.sh` first (Step 5).

### Site not loading after deploy
Check Cloudflare DNS points to the new IP (Step 4).

### Cloud-init still running
Wait for it to finish. Check with `cloud-init status`.

### Docker containers keep restarting
Check logs: `docker logs the-greatest-web`
Usually means `.env` file is missing — run the GitHub Actions deploy or decrypt secrets manually.

---

## Quick Reference

| Step | Command/Action |
|------|----------------|
| Preview changes | `terraform plan` |
| Apply changes | `terraform apply` |
| Monitor cloud-init | `sudo tail -f /var/log/cloud-init-output.log` |
| Update DNS | Cloudflare dashboard (manual) |
| Generate certs | `sudo deployment/scripts/generate-certs.sh` |
| Deploy app | GitHub Actions → "Deploy to Production" → Run workflow |
| Check containers | `docker ps` |
