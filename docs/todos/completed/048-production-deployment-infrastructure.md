# 048 - Production Deployment Infrastructure

## Status
- **Status**: In Progress
- **Priority**: High
- **Created**: 2025-10-11
- **Started**: 2025-10-11
- **Completed**:
- **Developer**: Shane Sherman

## Overview
Set up complete production deployment infrastructure for The Greatest multi-domain application. This includes Docker containerization, multi-container orchestration with nginx reverse proxy, SSL certificate management, database configuration for remote services, and GitHub Actions CI/CD pipeline.

## Context
The application is a multi-domain Rails app serving thegreatestmusic.org, thegreatest.games, and thegreatestmovies.org from a single codebase. The deployment needs to:
- Handle multiple domains through nginx (replacing Caddy from dev)
- Run separate web and worker containers
- Connect to existing external PostgreSQL and OpenSearch instances
- Automatically deploy via GitHub Actions
- Generate and renew SSL certificates via Cloudflare DNS and Let's Encrypt
- Be manageable by AI agents with minimal human intervention

## Requirements

### Infrastructure (Terraform)
- [x] Terraform configuration for Linode instance provisioning
- [x] Cloud-init setup with docker, git, fail2ban, ufw
- [x] Deploy user with docker group access
- [x] Automatic repository cloning on instance creation

### Docker Configuration
- [x] Fix/verify production Dockerfile works correctly (web-app/Dockerfile)
- [ ] Create docker-compose.prod.yml (in project root) with three services:
  - `web`: Rails application server (Thruster + Puma)
  - `worker`: Sidekiq background job processor
  - `nginx`: Reverse proxy with SSL termination
- [ ] Configure log rotation for all services to prevent disk space issues:
  - Use json-file driver with max-size: "10m" and max-file: "3"
  - Define as x-logging anchor and apply to all services
- [ ] Dockerfile should build assets and run migrations on startup
- [ ] Both web and worker should use same base image
- [ ] Proper health checks for all services
- [ ] Volume mounts for logs and persistent data

### SSL Certificate Management
- [ ] deployment/scripts/generate-certs.sh - Generate certificates using Cloudflare DNS-01 challenge
- [ ] deployment/scripts/renew-certs.sh - Renew certificates (can be run via cron)
- [ ] Integration with Let's Encrypt/certbot
- [ ] Store certificates in mounted volume accessible to nginx
- [ ] Support for 6 domain variants (www + non-www for each):
  - thegreatestmusic.org, www.thegreatestmusic.org
  - thegreatest.games, www.thegreatest.games
  - thegreatestmovies.org, www.thegreatestmovies.org

### Nginx Configuration
- [ ] deployment/nginx/Dockerfile - Custom nginx image with bad-bot-blocker
- [ ] deployment/nginx/nginx.conf - Base nginx configuration
- [ ] deployment/nginx/the-greatest.conf.template - Site-specific config with template variables
  - Use ${CERT_PATH} for SSL certificate paths
  - Use ${KEY_PATH} for SSL key paths
  - Use other env vars as needed
- [ ] Template substitution on container startup (envsubst or similar)
- [ ] SSL termination for all domains (both www and non-www)
- [ ] Redirect www to non-www (or vice versa) for canonical URLs
- [ ] Support for 6 domains total (3 domains × 2 variants each):
  - thegreatestmusic.org + www.thegreatestmusic.org
  - thegreatest.games + www.thegreatest.games
  - thegreatestmovies.org + www.thegreatestmovies.org
- [ ] Proxy Firebase Auth endpoints to firebaseapp.com
- [ ] Proper headers (Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto)
- [ ] Pass through Cache-Control headers from Rails to Cloudflare
- [ ] Static asset serving optimization
- [ ] WebSocket support (if needed)
- [ ] Security headers (HSTS, etc.)
- [ ] Bad bot blocking via nginx-ultimate-bad-bot-blocker

### Database Configuration
- [ ] Update database.yml to support external PostgreSQL via ENV variables
- [ ] Add POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER, POSTGRES_PASSWORD to .env
- [ ] Support for existing deployed PostgreSQL instance
- [ ] Support for existing deployed OpenSearch instance
- [ ] Production connection pooling configuration

### GitHub Actions CI/CD
- [x] Workflow to build and push Docker image on push to main
- [x] Workflow to deploy to production via repository_dispatch
- [x] SSH into Linode instance as deploy user
- [x] Pull latest code
- [x] Pull and restart Docker containers
- [ ] Workflow to run tests on PR (optional enhancement)
- [ ] Run migrations explicitly (currently handled by entrypoint)
- [ ] Rollback capability on failure (optional enhancement)
- [ ] Slack/email notifications (optional enhancement)

### Documentation
- [ ] deployment/README.md - Main deployment guide
- [ ] deployment/ENV.md - Environment variable documentation
- [ ] deployment/MANUAL_DEPLOY.md - Manual deployment instructions (backup)
- [ ] deployment/TROUBLESHOOTING.md - Troubleshooting guide
- [ ] deployment/ROLLBACK.md - Rollback procedures

## Technical Approach

### File Structure
```
the-greatest/                     # Project root
├── docker-compose.prod.yml       # Multi-container orchestration (root level)
├── deployment/
│   ├── terraform/                # Infrastructure as code (COMPLETED)
│   │   ├── linode-web.tf
│   │   ├── variables.tf
│   │   └── web-cloud-init.yaml
│   ├── nginx/
│   │   ├── Dockerfile           # Custom nginx with bad-bot-blocker
│   │   ├── nginx.conf           # Base nginx configuration
│   │   └── the-greatest.conf.template  # Site config with template vars
│   ├── scripts/
│   │   ├── generate-certs.sh    # Initial SSL cert generation
│   │   └── renew-certs.sh       # SSL cert renewal (for cron)
│   ├── README.md                 # Main deployment guide
│   ├── ENV.md                    # Environment variables
│   ├── MANUAL_DEPLOY.md         # Manual deployment instructions
│   ├── TROUBLESHOOTING.md       # Common issues and solutions
│   └── ROLLBACK.md              # Rollback procedures
└── web-app/
    └── Dockerfile                # Rails application Dockerfile
```

### Docker Architecture
```
docker-compose.prod.yml
├── x-logging (anchor)           # Shared logging config to prevent disk issues
│   ├── driver: json-file
│   ├── max-size: 10m
│   └── max-file: 3
├── web (Rails + Thruster + Puma)
│   ├── Port: 3000 (internal)
│   ├── Env: RAILS_ENV=production
│   ├── Image: ghcr.io/ssherman/the-greatest:latest
│   ├── Logging: *default-logging
│   └── Depends on: postgres (external), opensearch (external)
├── worker (Rails + Sidekiq)
│   ├── No exposed ports
│   ├── Env: RAILS_ENV=production
│   ├── Image: ghcr.io/ssherman/the-greatest:latest
│   ├── Logging: *default-logging
│   └── Depends on: postgres (external), redis
└── nginx
    ├── Build: deployment/nginx/Dockerfile (custom image with bad-bot-blocker)
    ├── Ports: 80, 443 (external)
    ├── Volumes: SSL certificates, rendered configs, bad-bot-blocker configs
    ├── Env vars: CERT_PATH, KEY_PATH (for template substitution)
    ├── Logging: *default-logging
    └── Proxy to: web:3000
```

### Multi-Domain Routing (Nginx)
Current dev setup uses Caddyfile with:
- Automatic SSL via Cloudflare DNS
- Firebase Auth proxy for /__/auth* paths
- Reverse proxy to localhost:3000

Production nginx must replicate this for 6 domain variants:
- thegreatestmovies.org + www.thegreatestmovies.org
- thegreatestmusic.org + www.thegreatestmusic.org
- thegreatest.games + www.thegreatest.games

**Canonical URL Strategy**: Redirect www to non-www (e.g., www.thegreatestmusic.org → thegreatestmusic.org)

**Template Variables Strategy**:
- Use `the-greatest.conf.template` with environment variable placeholders
- Substitute variables on container startup using `envsubst` or custom script
- Example variables: `${CERT_PATH}`, `${KEY_PATH}`, `${WEB_HOST}`, etc.
- Rendered config written to `/etc/nginx/conf.d/the-greatest.conf`
- All config files in source control (templates and base configs)

Note: thegreatestbooks.org will be skipped for now and launched later.

### SSL Certificate Generation Flow
1. certbot with Cloudflare DNS plugin
2. DNS-01 challenge using CLOUDFLARE_API_TOKEN
3. Wildcard certificates or individual domain certs
4. Auto-renewal via cron job running docker exec
5. Nginx reload after renewal

### GitHub Actions Deployment Flow

**Build Workflow** (`.github/workflows/build-web-image.yml`):
1. Triggers on push to main branch
2. Builds Docker image from `web-app/Dockerfile`
3. Pushes to GitHub Container Registry (ghcr.io/ssherman/the-greatest)
4. Tags: latest, branch name, SHA
5. Cleans up old images (keeps 20 most recent)
6. Triggers deploy workflow via repository_dispatch event

**Deploy Workflow** (`.github/workflows/deploy-web.yml`):
1. Triggers on repository_dispatch (image-built-event)
2. SSHs to production server as deploy user
3. Changes to `/home/deploy/apps/the-greatest`
4. Runs `docker system prune -f` to clean up
5. Runs `git pull` to get latest code
6. Runs `docker compose -f docker-compose.prod.yml pull` to pull latest images
7. Runs `docker compose -f docker-compose.prod.yml up -d` to restart services

**Note**: Test workflow for PRs not yet implemented (optional enhancement).

### Database Configuration Strategy
Current database.yml has hardcoded localhost values. Update to:

```yaml
production:
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 50 } %>
  host: <%= ENV.fetch("POSTGRES_HOST", "localhost") %>
  port: <%= ENV.fetch("POSTGRES_PORT", "5432") %>
  database: <%= ENV.fetch("POSTGRES_DATABASE", "the_greatest_production") %>
  username: <%= ENV.fetch("POSTGRES_USER", "the_greatest") %>
  password: <%= ENV["POSTGRES_PASSWORD"] %>
```

Similar approach for OpenSearch configuration.

## Dependencies
- Existing Terraform setup (COMPLETE)
- Existing cloud-init configuration (COMPLETE)
- Linode instance provisioned and accessible
- External PostgreSQL database (already deployed)
- External OpenSearch instance (already deployed)
- Cloudflare DNS management access
- GitHub repository with Actions enabled
- Docker installed on production server (via cloud-init)

## Acceptance Criteria
- [ ] Terraform provisions fresh Linode instance successfully
- [ ] Cloud-init runs and sets up deploy user, docker, firewall
- [ ] docker-compose.prod.yml launches all three services
- [ ] All 6 domain variants resolve and serve correct content via nginx
- [ ] www domains redirect to non-www (canonical URLs)
- [ ] Bad bot blocking is active and blocking malicious traffic
- [ ] SSL certificates are valid and auto-renewing
- [ ] Rails application connects to external PostgreSQL
- [ ] Sidekiq worker processes background jobs
- [ ] GitHub Actions deploys code changes automatically
- [ ] Zero-downtime deployments (existing requests complete)
- [ ] Logs accessible via docker-compose logs
- [ ] Log rotation working (max 30MB total per service: 3 files × 10MB)
- [ ] Application survives server restart (services auto-start)

## Design Decisions

### Why docker-compose over Kubernetes?
- Single-server deployment sufficient for MVP
- Simpler to manage and debug
- AI agents can understand docker-compose easily
- Can migrate to k8s later if needed

### Why nginx over Caddy in production?
- More mature and widely documented
- Better AI agent support (more training data)
- More control over configuration
- Caddy can remain for local dev

### Why separate web and worker containers?
- Allows independent scaling
- Worker can restart without affecting web traffic
- Clear separation of concerns
- Different resource requirements

### Why not use Kamal?
- Docker compose provides more transparency
- Easier for AI agents to debug and modify
- More explicit configuration
- Can add Kamal layer later if desired

### SSL Certificate Strategy: Wildcard vs Individual
Will implement **individual domain certificates with SAN** because:
- Have different TLDs (.org for music/movies, .games for games)
- More explicit and easier to debug
- Cloudflare DNS-01 challenge supports multiple domains
- Can combine www and non-www into single cert with SAN (Subject Alternative Names)
- Need 6 domain variants total:
  - thegreatestmusic.org + www.thegreatestmusic.org (one cert with SAN)
  - thegreatest.games + www.thegreatest.games (one cert with SAN)
  - thegreatestmovies.org + www.thegreatestmovies.org (one cert with SAN)

## Related Tasks
- 001-multi-domain-routing.md (architecture foundation)
- 003-firebase-auth.md (authentication integration)
- Future: Production monitoring and alerting
- Future: Backup and disaster recovery procedures

## Security Considerations
- SSL certificates stored securely in docker volumes
- Secrets managed via environment variables, never committed
- Cloudflare API token with minimal permissions (DNS edit only)
- Deploy user has limited sudo access
- UFW firewall blocks all but SSH, HTTP, HTTPS
- Fail2ban protects SSH from brute force
- Database credentials rotated regularly
- GitHub Actions uses encrypted secrets
- Container images scanned for vulnerabilities (future)

## Performance Considerations
- Nginx caching for static assets
- Connection pooling for database (50 connections)
- Sidekiq concurrency tuned based on server resources
- Docker log rotation (10MB max size, 3 files max) to prevent disk fill
- Monitor disk usage regularly (logs can accumulate quickly)
- Monitor memory usage (Linode nanode has 1GB RAM)
- Consider upgrading instance size if needed

---

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Completed Steps
1. **Terraform Infrastructure** (2025-10-09 - COMPLETED)
   - Created linode-web.tf with instance provisioning
   - Created variables.tf with configuration options
   - Created web-cloud-init.yaml with:
     - Deploy user with sudo and docker access
     - Package installation (docker, git, fail2ban, ufw)
     - Firewall configuration (SSH, HTTP, HTTPS only)
     - Automatic repository cloning script
     - Fail2ban enabled for SSH protection

2. **Production Dockerfile** (2025-10-11 - COMPLETED)
   - Verified existing Dockerfile works correctly
   - Multi-stage build with Ruby 3.4.7
   - Node 22.20.0 for asset compilation
   - Assets precompiled during build
   - Runs as non-root user (rails:rails)
   - Exposes port 80 for Thruster
   - Docker entrypoint handles database preparation

3. **GitHub Actions CI/CD** (2025-10-11 - COMPLETED)
   - Created .github/workflows/build-web-image.yml:
     - Triggers on push to main branch
     - Builds and pushes Docker image to GitHub Container Registry (ghcr.io)
     - Tags images with branch, SHA, and latest
     - Uses GitHub Actions cache for faster builds
     - Cleans up old images (keeps 20 most recent)
     - Triggers deploy workflow via repository_dispatch event
   - Created .github/workflows/deploy-web.yml:
     - Triggers on repository_dispatch (image-built-event)
     - SSHs to production server as deploy user
     - Pulls latest code from git
     - Pulls latest Docker images
     - Restarts containers with docker-compose
     - Runs docker system prune to clean up unused resources

### Approach Taken
*To be documented during implementation*

### Key Files Changed
*To be documented during implementation*

### Challenges Encountered
**Previous Issue with Log Disk Space**:
- Previously experienced disk space exhaustion due to unbounded Docker logs
- Logs accumulated until disk filled completely
- Solution: Configure log rotation at docker-compose level using json-file driver with size limits

**Code Review Issues Found (2025-10-15)**:

*P0 - SSL Certificate Volume Mounting*:
- **Issue**: Used Docker-managed named volumes (`letsencrypt-certs:/etc/letsencrypt:ro`) for nginx SSL certificates, but `generate-certs.sh` writes certificates to `/etc/letsencrypt` on the host filesystem
- **Impact**: Certificates generated on host would never appear in the nginx container, causing nginx to fail at startup with "SSL certificate not found" errors
- **Root Cause**: Docker-managed volumes are isolated from the host filesystem - the two are completely separate locations
- **Solution**: Changed to bind mounts matching working books site setup:
  - `/etc/letsencrypt/live:/etc/letsencrypt/live:ro`
  - `/etc/letsencrypt/archive:/etc/letsencrypt/archive:ro`
  - `/etc/letsencrypt/renewal:/etc/letsencrypt/renewal:ro`
  - `/var/www/certbot:/var/www/certbot:ro`
- **Files Changed**: docker-compose.prod.yml:77-80, removed unused named volumes
- **Reference**: Confirmed correct approach by examining working production setup for books site

*P1 - Missing Docker Compose Plugin*:
- **Issue**: Deployment workflow uses `docker compose` (Compose V2 plugin syntax) but cloud-init only installed `docker.io` package
- **Impact**: First deployment would fail with `docker: 'compose' is not a docker command` error on fresh Ubuntu 24.04 instances
- **Root Cause**: Docker Compose V2 plugin (`docker-compose-plugin`) is a separate package from `docker.io`
- **Solution**: Added `docker-compose-plugin` to cloud-init packages list
- **Files Changed**: deployment/terraform/web-cloud-init.yaml:20
- **Note**: This is the modern, recommended approach for Docker Compose installation (plugin vs standalone binary)

### Deviations from Plan
*To be documented during implementation*

### Testing Approach
Manual testing will include:
1. Terraform apply on fresh setup
2. SSH to instance and verify docker, deploy user, repo clone
3. Run docker-compose up and verify all services start
4. Test each domain in browser (6 variants total)
5. Verify www redirects to non-www
6. Verify SSL certificates valid for all domains
7. Test bad bot blocking (curl with known bad user agent)
8. Verify log rotation config (docker inspect <container> | grep -A 10 LogConfig)
9. Generate logs and verify old logs are rotated out
10. Test GitHub Actions deploy
11. Verify zero-downtime by monitoring active requests during deploy
12. Test rollback procedure
13. Test certificate renewal script

### Future Improvements
- Automated backups of application data
- Monitoring with Prometheus/Grafana or similar
- Log aggregation (ELK stack or similar)
- Blue-green deployment for true zero-downtime
- Kubernetes migration if scaling needed
- CDN integration (Cloudflare or AWS CloudFront)
- Database connection pooling via PgBouncer
- Redis Sentinel for high availability

### Lessons Learned
*To be documented during implementation*

### Related PRs
*To be documented when PRs are created*

### Documentation Updated
- [ ] deployment/README.md created
- [ ] deployment/ENV.md with environment variables (including nginx template vars)
- [ ] deployment/MANUAL_DEPLOY.md with manual instructions
- [ ] deployment/TROUBLESHOOTING.md with common issues
- [ ] deployment/ROLLBACK.md with rollback procedures
- [ ] Document nginx template variables and how substitution works
- [ ] Main README updated with link to deployment docs
