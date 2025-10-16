# 051 - Fix Production Deployment Issues

## Status
- **Status**: In Progress
- **Priority**: High
- **Created**: 2025-10-16
- **Started**: 2025-10-16
- **Completed**:
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
- [ ] Remove duplicate triggers from `deploy-production.yml` that cause race conditions
- [ ] Ensure deployment ONLY triggers via `repository_dispatch` after image build completes
- [ ] Verify build workflow successfully triggers deploy workflow
- [ ] Add appropriate delays or status checks if needed

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

1. **GitHub Actions Race Condition Fix** (2025-10-16 - COMPLETED)
   - Removed `push` trigger from `.github/workflows/deploy-production.yml`
   - Deploy workflow now ONLY triggers via:
     - `workflow_dispatch` (manual triggers)
     - `repository_dispatch` with `image-built-event` type (from build workflow)
   - This ensures build workflow completes before deployment starts
   - Sequential execution: push → build → dispatch event → deploy

2. **Docker Compose Plugin Testing** (2025-10-16 - PENDING MANUAL TESTING)
   - Need to verify if `docker-compose-plugin` package installation works
   - Previous server may not have had Terraform applied with this package
   - Backing out verification code until manual test on fresh server
   - Will add verification loop if needed after confirming base installation works

### Approach Taken

**Issue 1 - Workflow Timing:**
- Simple and direct: removed the problematic `push` trigger
- Kept `workflow_dispatch` for manual deployments
- Relies on `repository_dispatch` from build workflow for automatic deployments
- This is the cleanest solution with no race conditions possible

**Issue 2 - Docker Compose Plugin:**
- Waiting for manual testing on fresh Terraform-provisioned server
- Cloud-init already has `docker-compose-plugin` in packages list (line 20)
- Need to verify if plugin installation works without additional changes
- Will add verification/fallback if needed based on test results

### Key Files Changed
- `.github/workflows/deploy-production.yml`:4-6 - Removed `push` trigger (only workflow_dispatch and repository_dispatch remain)

### Challenges Encountered
*To be documented during implementation*

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
*To be documented during implementation*

### Related PRs
*To be documented when PRs are created*

### Documentation Updated
- [ ] This task file with implementation notes
- [ ] Task 048 updated with fixes and corrections
- [ ] Task 049 updated if deployment process changes
- [ ] deployment/TROUBLESHOOTING.md with common issues (when created)
