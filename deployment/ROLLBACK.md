# Rollback Procedures

This guide covers how to rollback The Greatest application to a previous working state in case of deployment failures.

## Table of Contents

- [Quick Rollback](#quick-rollback)
- [Rollback Scenarios](#rollback-scenarios)
- [Rollback Strategies](#rollback-strategies)
- [Testing After Rollback](#testing-after-rollback)
- [Prevention](#prevention)

## Quick Rollback

If you need to rollback immediately:

### Option 1: Rollback to Previous Docker Image

```bash
cd /home/deploy/apps/the-greatest

# Find previous working image
docker images ghcr.io/ssherman/the-greatest

# Update docker-compose.prod.yml to use specific image tag
# Replace 'latest' with specific SHA or tag
nano docker-compose.prod.yml

# Restart services
docker compose -f docker-compose.prod.yml up -d
```

### Option 2: Rollback Git Repository

```bash
cd /home/deploy/apps/the-greatest

# Find commit to rollback to
git log --oneline -10

# Rollback to specific commit
git reset --hard <commit-hash>

# If already pushed, create revert commit instead
git revert <bad-commit-hash>
git push origin main

# Rebuild or pull previous image
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
```

### Option 3: Emergency Rollback (Keep Container Running)

```bash
# Rollback code inside running container (temporary)
docker compose -f docker-compose.prod.yml exec web git reset --hard <commit-hash>
docker compose -f docker-compose.prod.yml restart web worker
```

## Rollback Scenarios

### Scenario 1: Application Code Issues

**Symptoms**: Application crashes, 500 errors, broken functionality.

**Rollback Steps**:

1. **Identify last working commit**
   ```bash
   git log --oneline
   ```

2. **Rollback git repository**
   ```bash
   git reset --hard <last-good-commit>
   ```

3. **Rebuild or use previous image**
   ```bash
   # Option A: Use previous image by tag
   docker compose -f docker-compose.prod.yml pull

   # Option B: Rebuild from current code
   cd web-app
   docker build -t ghcr.io/ssherman/the-greatest:rollback .
   ```

4. **Update docker-compose.prod.yml**
   ```yaml
   services:
     web:
       image: ghcr.io/ssherman/the-greatest:rollback
     worker:
       image: ghcr.io/ssherman/the-greatest:rollback
   ```

5. **Restart services**
   ```bash
   docker compose -f docker-compose.prod.yml up -d
   ```

6. **Verify application works**
   ```bash
   curl -I https://thegreatestmusic.org
   docker compose -f docker-compose.prod.yml logs -f web
   ```

### Scenario 2: Database Migration Issues

**Symptoms**: Migration fails, database errors, data corruption.

**Rollback Steps**:

1. **Check migration status**
   ```bash
   docker compose -f docker-compose.prod.yml exec web bin/rails db:migrate:status
   ```

2. **Rollback specific migration**
   ```bash
   # Rollback one migration
   docker compose -f docker-compose.prod.yml exec web bin/rails db:rollback

   # Rollback to specific version
   docker compose -f docker-compose.prod.yml exec web bin/rails db:migrate:down VERSION=20250110123456
   ```

3. **Restore from database backup** (if needed)
   ```bash
   # Stop application
   docker compose -f docker-compose.prod.yml stop web worker

   # Restore database
   pg_restore -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DATABASE backup.dump

   # Or from SQL dump
   psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DATABASE < backup.sql

   # Start application with old code
   git reset --hard <commit-before-migration>
   docker compose -f docker-compose.prod.yml up -d
   ```

4. **Verify database state**
   ```bash
   docker compose -f docker-compose.prod.yml exec web bin/rails runner "puts User.count"
   ```

### Scenario 3: Configuration Changes

**Symptoms**: Environment variable issues, nginx misconfiguration, SSL problems.

**Rollback Steps**:

1. **Restore previous .env file**
   ```bash
   cp .env.backup .env
   ```

2. **Restore nginx configuration**
   ```bash
   git checkout deployment/nginx/
   ```

3. **Rebuild nginx container**
   ```bash
   docker compose -f docker-compose.prod.yml build nginx
   ```

4. **Restart affected services**
   ```bash
   docker compose -f docker-compose.prod.yml restart
   ```

5. **Test configuration**
   ```bash
   docker compose -f docker-compose.prod.yml exec nginx nginx -t
   ```

### Scenario 4: SSL Certificate Issues

**Symptoms**: SSL errors, certificate validation failures.

**Rollback Steps**:

1. **Restore previous certificates** (if backed up)
   ```bash
   sudo cp -r /etc/letsencrypt.backup/* /etc/letsencrypt/
   ```

2. **Or regenerate certificates**
   ```bash
   export CLOUDFLARE_API_TOKEN=your_token
   sudo ./deployment/scripts/generate-certs.sh
   ```

3. **Reload nginx**
   ```bash
   docker compose -f docker-compose.prod.yml exec nginx nginx -s reload
   ```

4. **Test SSL**
   ```bash
   openssl s_client -connect thegreatestmusic.org:443 -servername thegreatestmusic.org
   ```

### Scenario 5: Docker Image Issues

**Symptoms**: Container won't start, image corruption, missing dependencies.

**Rollback Steps**:

1. **List available images**
   ```bash
   docker images ghcr.io/ssherman/the-greatest
   ```

2. **Tag previous working image**
   ```bash
   docker tag ghcr.io/ssherman/the-greatest:<previous-sha> ghcr.io/ssherman/the-greatest:rollback
   ```

3. **Update docker-compose.prod.yml**
   ```yaml
   services:
     web:
       image: ghcr.io/ssherman/the-greatest:rollback
     worker:
       image: ghcr.io/ssherman/the-greatest:rollback
   ```

4. **Restart services**
   ```bash
   docker compose -f docker-compose.prod.yml up -d
   ```

## Rollback Strategies

### Strategy 1: Blue-Green Deployment (Recommended for Future)

Not currently implemented, but recommended for zero-downtime rollbacks:

1. Deploy new version to separate containers
2. Test new version
3. Switch nginx to point to new version
4. Keep old version running for quick rollback
5. Remove old version after verification

### Strategy 2: Git-Based Rollback

Safest for preserving history:

```bash
# Create revert commit (preserves history)
git revert <bad-commit>
git push origin main

# Trigger deployment
# GitHub Actions will automatically deploy reverted code
```

### Strategy 3: Image Tag Rollback

Quick rollback using specific image tags:

```bash
# Use specific image version
docker compose -f docker-compose.prod.yml pull
docker tag ghcr.io/ssherman/the-greatest:sha-abc123 ghcr.io/ssherman/the-greatest:latest
docker compose -f docker-compose.prod.yml up -d
```

### Strategy 4: Snapshot Rollback (Linode)

For catastrophic failures:

1. Log in to Linode dashboard
2. Navigate to Linodes > the-greatest-web
3. Select "Backups" or "Snapshots"
4. Restore from previous snapshot
5. Reconfigure DNS if needed

## Testing After Rollback

After any rollback, perform these checks:

### 1. Service Health
```bash
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs --tail 100
```

### 2. Database Connectivity
```bash
docker compose -f docker-compose.prod.yml exec web bin/rails runner "puts ActiveRecord::Base.connection.execute('SELECT 1').first"
```

### 3. Application Endpoints
```bash
curl -I https://thegreatestmusic.org
curl -I https://thegreatest.games
curl -I https://thegreatestmovies.org
```

### 4. Background Jobs
```bash
docker compose -f docker-compose.prod.yml exec worker ps aux | grep sidekiq
```

### 5. User Authentication
Test Firebase auth flow in browser for each domain.

### 6. Critical User Flows
- User registration
- User login
- Browse content
- Search functionality
- Add to list functionality

## Post-Rollback Actions

1. **Document the incident**
   - What went wrong
   - What was rolled back
   - Current system state
   - Steps taken

2. **Notify stakeholders**
   - Team members
   - Users (if necessary)
   - Status page update

3. **Investigate root cause**
   - Review logs
   - Identify bug
   - Create fix
   - Add tests

4. **Plan re-deployment**
   - Fix issues
   - Test thoroughly in staging
   - Schedule deployment
   - Monitor closely

5. **Update monitoring**
   - Add alerts for similar issues
   - Improve health checks
   - Enhance logging

## Prevention

### Before Deployment

1. **Test in staging environment**
   ```bash
   # Use staging docker-compose
   docker compose -f docker-compose.staging.yml up -d
   ```

2. **Run full test suite**
   ```bash
   cd web-app
   bin/rails test
   ```

3. **Review changes**
   ```bash
   git diff main..deployment
   ```

4. **Database backup**
   ```bash
   pg_dump -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DATABASE > backup-$(date +%Y%m%d-%H%M%S).sql
   ```

5. **Tag release**
   ```bash
   git tag -a v1.2.3 -m "Release 1.2.3"
   git push origin v1.2.3
   ```

### During Deployment

1. **Monitor logs in real-time**
   ```bash
   docker compose -f docker-compose.prod.yml logs -f
   ```

2. **Watch resource usage**
   ```bash
   docker stats
   ```

3. **Test endpoints immediately**
   ```bash
   curl -I https://thegreatestmusic.org
   ```

4. **Check error rates**
   Monitor application logs and error tracking service.

### After Deployment

1. **Monitor for 30 minutes**
   Watch logs and metrics closely.

2. **Test critical paths**
   Perform manual testing of key features.

3. **Review performance**
   Check response times and resource usage.

4. **Keep previous version accessible**
   Don't delete previous Docker images immediately.

## Backup Strategy

Maintain regular backups to enable quick rollbacks:

### Database Backups
```bash
# Daily backup cron job
0 2 * * * pg_dump -h $POSTGRES_HOST -U $POSTGRES_USER $POSTGRES_DATABASE | gzip > /backups/db-$(date +\%Y\%m\%d).sql.gz
```

### Configuration Backups
```bash
# Backup before changes
cp .env .env.backup-$(date +%Y%m%d)
```

### Code Backups
```bash
# Git is the backup, but tag important releases
git tag -a v1.0.0 -m "Production release 1.0.0"
```

### Image Backups
Docker images in GHCR serve as backups. Keep multiple tagged versions.

## Emergency Contacts

If rollback fails or you need assistance:

1. Check TROUBLESHOOTING.md
2. Review deployment logs
3. Consult team members
4. Consider restoring from snapshot

## Recovery Time Objectives

- **Code rollback**: 5-10 minutes
- **Database rollback**: 15-30 minutes (depending on backup size)
- **Full system restore from snapshot**: 30-60 minutes
- **SSL certificate reissue**: 10-15 minutes

## Lessons Learned

After each rollback, document:

1. Root cause analysis
2. Impact assessment
3. Response timeline
4. What worked well
5. What needs improvement
6. Action items for prevention
