# 051 - Fix Production Deployment Issues

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-10-16
- **Started**: 2025-10-16
- **Completed**: 2025-10-17
- **Developer**: Shane Sherman

## Overview
Fix critical issues discovered during manual testing of production deployment infrastructure. Two main problems identified:
1. GitHub Actions deployment workflow triggers too early (before Docker image build completes)
2. Docker Compose commands failing due to missing plugin on production server

## Context
After implementing tasks 048 (Production Deployment Infrastructure) and 049 (SOPS Secrets Management), manual testing revealed that the deployment process has timing and dependency issues that prevent successful deployments.

The current workflow has `deploy-production.yml` triggering on both:
- `push` to `main` branch
- `repository_dispatch` event from build workflow

This causes a race condition where deployment attempts to run before the new Docker image is built and pushed to the registry.

Additionally, the production server's cloud-init installs `docker-compose-plugin` but Docker Compose V2 commands are failing with "unknown shorthand flag: 'f' in -f" errors, suggesting the plugin may not be properly installed or configured.

## Requirements

### Issue 1: Workflow Timing (Race Condition)
- [x] Remove duplicate triggers from `deploy-production.yml` that cause race conditions
- [x] Ensure deployment ONLY triggers via `repository_dispatch` after image build completes
- [x] Upgrade repository-dispatch action to v4
- [x] Fix PAT token secret name and configuration
- [ ] Create REPO_DISPATCH_PAT secret in GitHub (manual step)
- [ ] Verify build workflow successfully triggers deploy workflow

### Issue 2: Docker Compose Plugin Installation
- [ ] Verify Docker Compose V2 plugin installation in cloud-init
- [ ] Test that `docker compose` (not `docker-compose`) commands work on fresh instance
- [ ] Add verification step to cloud-init to confirm installation
- [ ] Document correct Docker Compose commands for deployment
- [ ] Consider fallback to standalone docker-compose binary if plugin approach fails

### Testing & Verification
- [ ] Test fresh Terraform instance provisioning
- [ ] Verify cloud-init completes successfully
- [ ] Manually test `docker compose` commands on server
- [ ] Trigger full CI/CD pipeline (push to main → build → deploy)
- [ ] Verify services start successfully after deployment
- [ ] Check deployment logs for errors

## Technical Approach

### Issue 1 Solution: Fix Workflow Triggers

**Current Problem:**
```yaml
# deploy-production.yml (PROBLEMATIC)
on:
  workflow_dispatch:         # Manual trigger (OK)
  push:
    branches:
      - main                 # ❌ Triggers immediately with build workflow
  repository_dispatch:
    types: [image-built-event]  # ✅ Should be the only automatic trigger
```

**Proposed Fix:**
```yaml
# deploy-production.yml (CORRECTED)
on:
  workflow_dispatch:         # Keep for manual deployments
  repository_dispatch:
    types: [image-built-event]  # ONLY automatic trigger (after build completes)
```

This ensures:
1. Build workflow runs on push to main
2. Build workflow completes and pushes image
3. Build workflow triggers `image-built-event`
4. Deploy workflow receives event and starts deployment
5. Sequential execution guaranteed

### Issue 2 Solution: Fix Docker Compose Installation

**Current Cloud-init:**
```yaml
packages:
  - docker-compose-plugin  # Installed but commands failing
```

**Investigation Steps:**
1. SSH to fresh instance after cloud-init completes
2. Run `docker compose version` to verify plugin installation
3. Check `docker info` for Compose plugin in active plugins list
4. Review cloud-init logs: `sudo cat /var/log/cloud-init-output.log`

**Potential Solutions (in order of preference):**

**Option A: Add Docker Compose V2 plugin verification (Preferred)**
```yaml
runcmd:
  # Existing commands...

  # Verify Docker Compose plugin installed
  - |
    until docker compose version; do
      echo "Waiting for Docker Compose plugin..."
      sleep 2
    done
```

**Option B: Install Docker Compose as standalone binary (Fallback)**
```yaml
runcmd:
  # Install Docker Compose standalone if plugin approach fails
  - curl -SL https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
  - chmod +x /usr/local/bin/docker-compose
  - ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
```

**Option C: Use Ubuntu's native docker-compose package**
```yaml
packages:
  - docker-compose  # Traditional package (may be older version)
```

### Deployment Workflow Commands

Ensure all Docker Compose commands use correct syntax:
```bash
# ✅ Correct (Docker Compose V2 plugin)
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d

# ❌ Incorrect (hyphenated command for standalone binary)
docker-compose -f docker-compose.prod.yml pull
```

## Dependencies
- Task 048 (Production Deployment Infrastructure) - Base infrastructure
- Task 049 (SOPS Secrets Management) - Secrets handling
- GitHub Actions secrets configured (AGE_PRIVATE_KEY, DEPLOY_SSH_KEY, SERVER_WEB_HOST)
- GitHub Personal Access Token (PAT) for repository_dispatch

## Acceptance Criteria

### Workflow Timing
- [ ] Push to main triggers ONLY `build-web-image.yml`
- [ ] Build workflow completes and pushes Docker image to GHCR
- [ ] Build workflow triggers `repository_dispatch` event
- [ ] Deploy workflow receives event and starts AFTER build completes
- [ ] No race conditions or failed deployments due to missing images

### Docker Compose Functionality
- [ ] Fresh Terraform instance has working Docker Compose installation
- [ ] `docker compose version` command works on server
- [ ] `docker compose -f docker-compose.prod.yml pull` works
- [ ] `docker compose -f docker-compose.prod.yml up -d` works
- [ ] All services start successfully
- [ ] No "unknown shorthand flag" errors

### End-to-End Deployment
- [ ] Complete deployment succeeds from push to main
- [ ] All three services (web, worker, nginx) start correctly
- [ ] Services survive server restart
- [ ] Logs show no errors in GitHub Actions
- [ ] Application is accessible via all domains

## Design Decisions

### Why Remove `push` Trigger from Deploy Workflow?
- **Problem**: Creates race condition between build and deploy
- **Solution**: Deploy only via `repository_dispatch` ensures proper sequencing
- **Benefit**: Build must complete before deploy starts
- **Trade-off**: Slightly more complex workflow setup, but guaranteed correctness

### Why Prefer Docker Compose Plugin Over Standalone Binary?
- **Modern approach**: Docker Compose V2 as plugin is the official direction
- **Better integration**: Native Docker CLI integration
- **Automatic updates**: Updates with Docker Engine
- **Simpler syntax**: `docker compose` vs `docker-compose`
- **Fallback available**: Can install standalone binary if needed

### Why Not Use Kamal or Other Tools?
- Maintaining consistency with existing architecture decisions (see task 048)
- Docker Compose provides sufficient transparency for AI agents
- Simpler debugging and troubleshooting
- Can add higher-level tools later if needed

## Related Tasks
- 048-production-deployment-infrastructure.md (base infrastructure)
- 049-sops-secrets-management.md (secrets management)
- Future: Monitoring and alerting for deployment failures

## Security Considerations
- No changes to security posture
- Deployment workflow still uses SSH with key authentication
- Secrets management unchanged (SOPS + age)
- No new secrets or credentials required

## Performance Considerations
- Sequential workflow execution may add 2-3 minutes to deployment time
- This is acceptable trade-off for deployment reliability
- Docker image caching in GitHub Actions minimizes build time
- No performance impact on running application

---

## Implementation Notes

### Completed Steps

1. **GitHub Actions Race Condition Fix** (2025-10-16 - IN PROGRESS)
   - Removed `push` trigger from `.github/workflows/deploy-production.yml`
   - Deploy workflow now ONLY triggers via:
     - `workflow_dispatch` (manual triggers)
     - `repository_dispatch` with `image-built-event` type (from build workflow)
   - This ensures build workflow completes before deployment starts
   - Sequential execution: push → build → dispatch event → deploy
   - **Updated repository-dispatch action**:
     - Upgraded from v3 to v4
     - Changed token secret from `PAT` to `REPO_DISPATCH_PAT` (clearer naming)
     - Removed redundant `repository` parameter
   - **Pending**: Need to create REPO_DISPATCH_PAT secret in GitHub settings

2. **Docker Compose Plugin Installation** (2025-10-16 - COMPLETED)
   - **Problem identified**: Ubuntu's default `docker.io` package is outdated and doesn't include compose plugin
   - **Solution**: Install Docker from official Docker repository instead
   - **Changes made**:
     - Removed `docker.io` and `docker-compose-plugin` from packages list
     - Added Docker's official GPG key setup
     - Added Docker's official apt repository
     - Install `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`
     - Explicitly add deploy user to docker group with `usermod -aG docker deploy`
   - **Result**: Fresh installs will get latest Docker with full compose plugin support

3. **Environment Variables Issue** (2025-10-16 - DISCOVERED)
   - **Problem**: Rails containers restarting with `key must be 16 bytes (ArgumentError)`
   - **Root cause**: Issues with SECRET_KEY_BASE or RAILS_MASTER_KEY in .env file
   - **Status**: Pending investigation - need to verify .env file contents on server
   - **Next steps**: Check decrypted secrets, verify key lengths and formats

4. **Zeitwerk Autoloading Issue** (2025-10-16 - COMPLETED)
   - **Problem**: `uninitialized constant Music::Musicbrainz::Exceptions (NameError)`
   - **Root cause**: File named `exceptions.rb` but didn't define `Exceptions` module - Zeitwerk expects filename to match module name
   - **Solution**: Properly namespace all exception classes under `Music::Musicbrainz::Exceptions` module
   - **Changes made**:
     - Wrapped all exception classes in `exceptions.rb` with `module Exceptions`
     - Updated all references across codebase (57 updates in 17 files):
       - `Music::Musicbrainz::Error` → `Music::Musicbrainz::Exceptions::Error`
       - `Music::Musicbrainz::NetworkError` → `Music::Musicbrainz::Exceptions::NetworkError`
       - And 9 other exception classes
     - Fixed bare references in `base_client.rb` (e.g., `raise TimeoutError` → `raise Exceptions::TimeoutError`)
   - **Files updated**:
     - `app/lib/music/musicbrainz/exceptions.rb` - Added `module Exceptions` wrapper
     - `app/lib/music/musicbrainz/base_client.rb` - Fixed 9 bare exception references
     - 7 search classes in `app/lib/music/musicbrainz/search/`
     - 10 test files in `test/lib/music/musicbrainz/`
   - **Result**: Zeitwerk can properly autoload exception classes without conflicts

5. **Nginx Bad-Bot-Blocker Configuration** (2025-10-16 - COMPLETED)
   - **Problem**: `"if" directive is not allowed here in /etc/nginx/bots.d/blockbots.conf:62`
   - **Root cause**: `blockbots.conf` and `ddos.conf` were included at `http` level in `nginx.conf`, but these files contain `if` directives that must be at `server` block level
   - **Solution**: Move bot blocker includes from http level to server block level, AND mount nginx config files as volumes to avoid stale cached builds
   - **Changes made**:
     - Removed `include /etc/nginx/bots.d/blockbots.conf;` and `include /etc/nginx/bots.d/ddos.conf;` from `nginx.conf` (http level)
     - Added both includes to each of the 3 main server blocks in `the-greatest.conf.template`
     - Now included in: thegreatestmusic.org, thegreatest.games, and thegreatestmovies.org server blocks
     - Added volume mounts in `docker-compose.prod.yml` for all nginx config files to override baked-in files from Docker build
   - **Files updated**:
     - `deployment/nginx/nginx.conf` - Removed http-level bot blocker includes
     - `deployment/nginx/the-greatest.conf.template` - Added server-level bot blocker includes (3 locations)
     - `docker-compose.prod.yml` - Added 4 volume mounts for nginx configs (nginx.conf, template, 2 snippet files)
   - **Result**: Nginx uses latest config files without rebuilding, bad bot blocking active on all domains
   - **Deployment note**: After pulling updated code, run `docker compose -f docker-compose.prod.yml restart nginx` to pick up new configs

6. **Nginx HTTP/2 Deprecation Warnings** (2025-10-16 - COMPLETED)
   - **Problem**: `the "listen ... http2" directive is deprecated, use the "http2" directive instead`
   - **Root cause**: Using old nginx syntax `listen 443 ssl http2;` deprecated in nginx 1.25.1+
   - **Solution**: Update to modern nginx syntax with separate `http2 on;` directive
   - **Changes made**:
     - Changed all 6 SSL server blocks from `listen 443 ssl http2;` to `listen 443 ssl;` + `http2 on;`
     - Updated: 3 www redirect blocks + 3 main domain blocks
   - **Files updated**:
     - `deployment/nginx/the-greatest.conf.template` - Updated all 6 SSL server blocks
   - **Result**: No more deprecation warnings, modern nginx syntax throughout

7. **Nginx Bad-Bot-Blocker Missing Files** (2025-10-17 - COMPLETED)
   - **Problem**: `nginx: [emerg] unknown "bad_bot" variable`
   - **Root cause**: Dockerfile only downloaded `blockbots.conf` and `ddos.conf`, but missing the critical `globalblacklist.conf` file that defines the `$bad_bot`, `$bad_referer`, and `$bad_words` variables using map directives
   - **Solution**: Use the automated installer script instead of manually downloading individual files
   - **Changes made**:
     - Replaced manual curl downloads with automated `install-ngxblocker` script
     - Script downloads and configures all 10 required files automatically:
       - 2 files in `/etc/nginx/conf.d/`: `globalblacklist.conf`, `botblocker-nginx-settings.conf`
       - 8 files in `/etc/nginx/bots.d/`: blockbots, ddos, whitelists, blacklists, custom rules
     - Runs `setup-ngxblocker -x -e conf` to configure includes in nginx config
   - **How it works**:
     - nginx.conf line 46 includes `/etc/nginx/conf.d/*.conf` which loads globalblacklist.conf (defines variables at http level)
     - Server blocks include `blockbots.conf` and `ddos.conf` which use those variables
     - Variables must be defined before they're used, which is why http-level include comes first
   - **Files updated**:
     - `deployment/nginx/Dockerfile` - Replaced manual downloads with automated installer script (same approach as books site)
   - **Result**: Nginx can now start successfully with full bad-bot-blocker functionality
   - **Reference**: https://github.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker

### Approach Taken

**Issue 1 - Workflow Timing:**
- Simple and direct: removed the problematic `push` trigger
- Kept `workflow_dispatch` for manual deployments
- Relies on `repository_dispatch` from build workflow for automatic deployments
- This is the cleanest solution with no race conditions possible

**Issue 2 - Docker Compose Plugin:**
- Identified that Ubuntu's `docker.io` package doesn't include compose plugin
- Switched to official Docker repository for latest versions
- Installs Docker CE with all plugins (compose, buildx)
- Properly adds deploy user to docker group

### Key Files Changed

**GitHub Actions:**
- `.github/workflows/deploy-production.yml`:4-6 - Removed `push` trigger (only workflow_dispatch and repository_dispatch remain)
- `.github/workflows/build-web-image.yml`:76-80 - Upgraded repository-dispatch to v4, fixed PAT secret name

**Infrastructure:**
- `deployment/terraform/web-cloud-init.yaml`:16-22 - Removed Ubuntu docker packages
- `deployment/terraform/web-cloud-init.yaml`:47-57 - Added official Docker repository setup and installation

**Application Code (Zeitwerk Fix):**
- `web-app/app/lib/music/musicbrainz/exceptions.rb` - Added `module Exceptions` wrapper around all exception classes
- `web-app/app/lib/music/musicbrainz/base_client.rb` - Updated 9 exception references to use `Exceptions::` prefix
- `web-app/app/lib/music/musicbrainz/search/*.rb` - Updated 7 search classes (21 references)
- `web-app/test/lib/music/musicbrainz/**/*_test.rb` - Updated 10 test files (27 references)

**Nginx Configuration (Bad-Bot-Blocker Fix + HTTP/2 Syntax Update):**
- `deployment/nginx/nginx.conf` - Removed bot blocker includes from http level (lines 46-47 deleted)
- `deployment/nginx/the-greatest.conf.template` - Added bot blocker includes to 3 server blocks + updated HTTP/2 syntax in 6 server blocks
- `docker-compose.prod.yml` - Added volume mounts for nginx.conf and snippet files to override Docker build cache (lines 76-79)

### Manual Steps Required
1. **Create GitHub Personal Access Token**:

   **Option A - Classic PAT (Recommended for simplicity):**
   - Go to: https://github.com/settings/tokens (NOT /tokens?type=beta)
   - Click "Generate new token" → "Generate new token (classic)"
   - Note: `the-greatest-repository-dispatch`
   - Expiration: Choose preference (recommend 1 year)
   - Scopes: Check `repo` (or `public_repo` for public repos only)

   **Option B - Fine-Grained PAT (More restrictive):**
   - Go to: https://github.com/settings/tokens?type=beta
   - Click "Generate new token"
   - Repository access: Select "Only select repositories" → choose `the-greatest`
   - Repository permissions:
     - **Contents**: Read and write
     - **Metadata**: Read-only (auto-selected)
     - **Actions**: Read and write (REQUIRED to trigger workflows!)

2. **Add Secret to Repository**:
   - Go to: https://github.com/ssherman/the-greatest/settings/secrets/actions
   - Click "New repository secret"
   - Name: `REPO_DISPATCH_PAT`
   - Value: Paste the PAT created above
   - Click "Add secret"

### Challenges Encountered

1. **PAT Token Confusion** (2025-10-16)
   - Initial error: `Parameter token or opts.auth is required`
   - Issue: Missing `REPO_DISPATCH_PAT` secret in GitHub Actions
   - Then: `Resource not accessible by personal access token`
   - Root cause: Need to use Classic PAT with `repo` scope, OR fine-grained PAT with `Actions: Read and write` permission
   - Fine-grained tokens need specific permissions: Contents (R/W), Metadata (R), and **Actions (R/W)**
   - Recommended solution: Use Classic PAT for simplicity

2. **Terraform Template Syntax Error** (2025-10-16)
   - Error: `Invalid character; This character is not used within the language`
   - Issue: YAML multi-line `|` character in cloud-init caused Terraform templatefile() to fail
   - Solution: Changed from multi-line format to single-line string with proper escaping
   - Had to escape `$` as `$$` for Terraform (e.g., `$${UBUNTU_CODENAME}`)

3. **Secret Key Error** (2025-10-16)
   - Error: `key must be 16 bytes (ArgumentError)` in ActiveSupport::MessageEncryptor
   - Indicates issue with Rails secrets (SECRET_KEY_BASE or RAILS_MASTER_KEY)
   - Status: Pending investigation - need to verify decrypted .env contents on server

4. **Zeitwerk Autoloading** (2025-10-16)
   - Error: `uninitialized constant Music::Musicbrainz::Exceptions`
   - Issue: File named `exceptions.rb` but didn't define `Exceptions` module
   - Zeitwerk expects filename to match constant name
   - Initial mistake: Tried to use `collapse()` to work around it - wrong approach
   - Correct solution: Properly namespace exceptions and update all 57 references across 17 files

5. **Nginx Bad-Bot-Blocker Configuration** (2025-10-16)
   - Error: `"if" directive is not allowed here in /etc/nginx/bots.d/blockbots.conf:62`
   - Issue: Bot blocker config files were included at `http` level in nginx.conf
   - Problem: blockbots.conf and ddos.conf contain `if` directives that only work at `server` block level
   - Solution: Moved includes from http level to each individual server block
   - Additional fix: Added volume mounts in docker-compose.prod.yml to override baked-in nginx config from Docker build
   - Why volume mounts needed: nginx.conf is COPY'd during Docker build, so container had old version cached
   - Reference: nginx-ultimate-bad-bot-blocker documentation specifies server-level inclusion

6. **Nginx HTTP/2 Deprecation Warnings** (2025-10-16)
   - Warning: `the "listen ... http2" directive is deprecated, use the "http2" directive instead`
   - Issue: Using old nginx syntax `listen 443 ssl http2;` from pre-1.25.1 versions
   - Solution: Updated to modern syntax with separate `http2 on;` directive
   - Changed in all 6 SSL server blocks (3 www redirects + 3 main domains)

7. **Nginx Bad-Bot-Blocker Missing Files** (2025-10-17)
   - Error: `unknown "bad_bot" variable`
   - Issue: Dockerfile only downloaded `blockbots.conf` and `ddos.conf` but not the `globalblacklist.conf` file that defines the variables
   - Problem: The bot blocker requires 10 files total (2 in conf.d/, 8 in bots.d/)
   - Research findings: Used web-search-researcher agent to discover nginx-ultimate-bad-bot-blocker has automated installer
   - Solution: Use `install-ngxblocker` automated installer script (same approach as books site) instead of manually downloading files
   - Installer automatically downloads all 10 required files and configures nginx
   - Much simpler and more maintainable than manual downloads
   - How it works: nginx.conf includes `/etc/nginx/conf.d/*.conf` at http level (defines variables), then server blocks include `bots.d/*.conf` files (uses variables)
   - Reference: https://github.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker/blob/master/AUTO-CONFIGURATION.md

### Deviations from Plan
*To be documented during implementation*

### Testing Approach

**Local Testing:**
1. Review workflow YAML changes for syntax errors
2. Verify trigger logic is correct

**Server Testing:**
1. Provision fresh Linode instance via Terraform
2. Wait for cloud-init to complete (~2-5 minutes)
3. SSH to instance: `ssh deploy@<server-ip>`
4. Verify Docker Compose: `docker compose version`
5. Test commands manually:
   ```bash
   cd /home/deploy/apps/the-greatest
   docker compose -f docker-compose.prod.yml config
   docker compose -f docker-compose.prod.yml pull
   docker compose -f docker-compose.prod.yml up -d
   docker compose -f docker-compose.prod.yml ps
   ```

**CI/CD Testing:**
1. Push test commit to main branch
2. Monitor build workflow in GitHub Actions
3. Verify deploy workflow triggers ONLY after build completes
4. Check deployment logs for errors
5. Verify services running: `docker compose ps`
6. Test application endpoints

### Future Improvements
- Add deployment status notifications (Slack, email)
- Implement smoke tests after deployment
- Add rollback capability
- Monitor deployment metrics (time, success rate)
- Consider blue-green deployments for zero-downtime

### Lessons Learned

1. **Alpine vs Debian Docker images**: Alpine quirks (missing /usr/local/sbin) aren't worth the small size savings for nginx. Stick with Debian-based images.

2. **Automated installers > Manual downloads**: The nginx-ultimate-bad-bot-blocker automated installer is much simpler than manually tracking 10 files.

3. **Cloudflare proxy requires special handling**: When using Cloudflare's orange cloud proxy, check X-Forwarded-Proto header to avoid redirect loops.

4. **Docker entrypoint argument matching**: Be careful with argument position checks in entrypoint scripts - `CMD ["./bin/rails", "server", "-b", "0.0.0.0"]` has 3 args, not 2.

5. **Nginx template processing**: NGINX_ENVSUBST_OUTPUT_DIR must not conflict with conf.d where bot blocker files live. Use separate directories.

6. **Volume mounts override Docker COPY**: Mounting config files as volumes lets you update nginx config without rebuilding images.

7. **Domain environment variables**: Rails domain routing needs production domains in environment variables, not just nginx config.

8. **SSL certificates via DNS**: Certbot with Cloudflare DNS only creates TXT records for validation - you still need to manually add A records.

### Related PRs
- Changes included in deployment branch

### Documentation Updated
- [x] This task file with complete implementation notes
- [x] deployment/scripts/README.md - Added certbot Docker documentation
- [x] deployment/MANUAL_DEPLOY.md - Updated for Docker-based certbot
- [x] docs/sub-agents.md - Documented all sub-agent types

### Additional Issues Fixed

8. **Nginx Template Output Directory Conflict** (2025-10-17 - COMPLETED)
   - **Problem**: Template processing to `/etc/nginx/conf.d` overwrote bot blocker files
   - **Solution**: Changed NGINX_ENVSUBST_OUTPUT_DIR to `/etc/nginx/sites-enabled`
   - **Files updated**: docker-compose.prod.yml, nginx.conf, Dockerfile

9. **Nginx Sites-Enabled Directory Permissions** (2025-10-17 - COMPLETED)
   - **Problem**: `/etc/nginx/sites-enabled not writable` error during template processing
   - **Solution**: Added proper permissions in Dockerfile: `chown -R nginx:nginx /etc/nginx/sites-enabled`

10. **Cloudflare Redirect Loop** (2025-10-17 - COMPLETED)
    - **Problem**: Endless 301 redirects due to Cloudflare proxy sending HTTP to origin
    - **Solution**: Check X-Forwarded-Proto header before redirecting to HTTPS
    - **Files updated**: deployment/nginx/the-greatest.conf.template

11. **Rails Database Not Prepared** (2025-10-17 - COMPLETED)
    - **Problem**: Docker entrypoint db:prepare check failed due to `-b 0.0.0.0` argument
    - **Solution**: Changed check from position-based to pattern matching: `[[ "$*" == *"rails server"* ]]`
    - **Files updated**: web-app/bin/docker-entrypoint

12. **Production Domain Configuration** (2025-10-17 - COMPLETED)
    - **Problem**: Rails using dev domains (dev.thegreatestmusic.org) in production
    - **Solution**: Added MUSIC_DOMAIN, MOVIES_DOMAIN, GAMES_DOMAIN to secrets/.env.production
    - **Files updated**: secrets/.env.production (via SOPS)
