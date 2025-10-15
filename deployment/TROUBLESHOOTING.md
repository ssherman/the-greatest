# Troubleshooting Guide

Common issues and solutions for The Greatest production deployment.

## Table of Contents

- [Container Issues](#container-issues)
- [Database Issues](#database-issues)
- [SSL Certificate Issues](#ssl-certificate-issues)
- [Nginx Issues](#nginx-issues)
- [Performance Issues](#performance-issues)
- [Disk Space Issues](#disk-space-issues)
- [Network Issues](#network-issues)
- [Application Issues](#application-issues)

## Container Issues

### Container Won't Start

**Symptom**: Container exits immediately or shows unhealthy status.

**Diagnosis**:
```bash
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs web
docker compose -f docker-compose.prod.yml logs worker
```

**Common Causes**:

1. **Missing environment variables**
   ```bash
   # Check for missing variables
   docker compose -f docker-compose.prod.yml config
   ```
   Solution: Review ENV.md and add missing variables to .env file.

2. **Database connection failure**
   ```bash
   docker compose -f docker-compose.prod.yml exec web bin/rails runner "ActiveRecord::Base.connection"
   ```
   Solution: Verify POSTGRES_* variables and network connectivity.

3. **Image pull failure**
   ```bash
   docker pull ghcr.io/ssherman/the-greatest:latest
   ```
   Solution: Check GitHub Container Registry credentials and network.

### Container Keeps Restarting

**Symptom**: Container status shows "Restarting" continuously.

**Diagnosis**:
```bash
docker logs the-greatest-web --tail 100
docker logs the-greatest-worker --tail 100
```

**Common Causes**:

1. **Application crash on startup**
   Look for Ruby exceptions in logs.
   Solution: Fix application code or configuration.

2. **Out of memory**
   ```bash
   docker stats
   free -h
   ```
   Solution: Increase server resources or reduce container memory usage.

3. **Failed health check**
   ```bash
   docker inspect the-greatest-web | grep -A 20 Health
   ```
   Solution: Fix health check endpoint or adjust health check parameters.

## Database Issues

### Cannot Connect to Database

**Symptom**: Rails shows "could not connect to server" or "connection refused".

**Diagnosis**:
```bash
docker compose -f docker-compose.prod.yml exec web bin/rails runner "puts ActiveRecord::Base.connection.execute('SELECT version()').first"
```

**Solutions**:

1. **Check PostgreSQL is accessible**
   ```bash
   telnet $POSTGRES_HOST $POSTGRES_PORT
   # or
   nc -zv $POSTGRES_HOST $POSTGRES_PORT
   ```

2. **Verify credentials**
   ```bash
   docker compose -f docker-compose.prod.yml exec web env | grep POSTGRES
   ```
   Compare with actual database credentials.

3. **Check firewall rules**
   PostgreSQL server must allow connections from application server IP.

4. **Verify database exists**
   ```bash
   psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DATABASE -c "SELECT 1"
   ```

### Database Migration Failures

**Symptom**: Migrations fail during container startup.

**Diagnosis**:
```bash
docker compose -f docker-compose.prod.yml logs web | grep -i migration
```

**Solutions**:

1. **Run migrations manually**
   ```bash
   docker compose -f docker-compose.prod.yml exec web bin/rails db:migrate
   ```

2. **Check for locked migrations**
   ```bash
   docker compose -f docker-compose.prod.yml exec web bin/rails db:migrate:status
   ```

3. **Reset database (DESTRUCTIVE)**
   ```bash
   docker compose -f docker-compose.prod.yml exec web bin/rails db:reset
   ```

## SSL Certificate Issues

### Certificate Generation Fails

**Symptom**: generate-certs.sh exits with error.

**Diagnosis**:
```bash
sudo ./deployment/scripts/generate-certs.sh
```

**Common Causes**:

1. **Missing CLOUDFLARE_API_TOKEN**
   ```bash
   echo $CLOUDFLARE_API_TOKEN
   ```
   Solution: Export token before running script.

2. **Invalid API token**
   Verify token has DNS:Edit permissions in Cloudflare dashboard.

3. **DNS propagation timeout**
   Solution: Increase `--dns-cloudflare-propagation-seconds` in script.

4. **Rate limit exceeded**
   Let's Encrypt has rate limits (50 certificates per week per domain).
   Solution: Wait or use staging environment for testing.

### SSL Handshake Errors

**Symptom**: Browser shows "SSL_ERROR_BAD_CERT_DOMAIN" or similar.

**Diagnosis**:
```bash
openssl s_client -connect thegreatestmusic.org:443 -servername thegreatestmusic.org
```

**Solutions**:

1. **Certificate paths incorrect**
   Verify CERT_PATH and KEY_PATH in .env match actual certificate locations.

2. **Wrong certificate for domain**
   Check nginx configuration:
   ```bash
   docker compose -f docker-compose.prod.yml exec nginx nginx -T | grep ssl_certificate
   ```

3. **Certificate expired**
   ```bash
   openssl x509 -in /etc/letsencrypt/live/thegreatestmusic.org/cert.pem -noout -dates
   ```
   Solution: Run renew-certs.sh

### Certificate Renewal Fails

**Symptom**: renew-certs.sh exits with error.

**Diagnosis**:
```bash
sudo certbot renew --dry-run
```

**Solutions**:

1. **Cloudflare credentials missing**
   Check `/root/.secrets/certbot/cloudflare.ini` exists and contains valid token.

2. **Certificate not due for renewal**
   Certbot only renews certificates within 30 days of expiration.

3. **Nginx not reloading**
   Manually reload:
   ```bash
   docker compose -f docker-compose.prod.yml exec nginx nginx -s reload
   ```

## Nginx Issues

### 502 Bad Gateway

**Symptom**: All domains return 502 error.

**Diagnosis**:
```bash
docker compose -f docker-compose.prod.yml logs nginx
curl http://web:80/up  # from nginx container
```

**Solutions**:

1. **Web container not running**
   ```bash
   docker compose -f docker-compose.prod.yml ps web
   docker compose -f docker-compose.prod.yml restart web
   ```

2. **Web container not responding**
   ```bash
   docker compose -f docker-compose.prod.yml exec web curl http://localhost:80/up
   ```

3. **Network issue between containers**
   ```bash
   docker network inspect the-greatest
   ```

### 404 Not Found

**Symptom**: Specific routes return 404.

**Diagnosis**:
```bash
docker compose -f docker-compose.prod.yml logs nginx | grep 404
```

**Solutions**:

1. **Rails routing issue**
   ```bash
   docker compose -f docker-compose.prod.yml exec web bin/rails routes | grep path
   ```

2. **Nginx location block not matching**
   Check nginx configuration:
   ```bash
   docker compose -f docker-compose.prod.yml exec nginx cat /etc/nginx/conf.d/the-greatest.conf
   ```

### Nginx Configuration Errors

**Symptom**: Nginx container fails to start.

**Diagnosis**:
```bash
docker compose -f docker-compose.prod.yml logs nginx
docker compose -f docker-compose.prod.yml exec nginx nginx -t
```

**Solutions**:

1. **Template substitution failed**
   Check environment variables are set:
   ```bash
   docker compose -f docker-compose.prod.yml exec nginx env | grep -E 'WEB_HOST|WEB_PORT|CERT_PATH'
   ```

2. **SSL certificate files missing**
   ```bash
   docker compose -f docker-compose.prod.yml exec nginx ls -la /etc/letsencrypt/live/
   ```

3. **Syntax error in configuration**
   Test configuration:
   ```bash
   docker compose -f docker-compose.prod.yml exec nginx nginx -t
   ```

## Performance Issues

### Slow Response Times

**Symptom**: Pages load slowly or timeout.

**Diagnosis**:
```bash
docker stats
docker compose -f docker-compose.prod.yml exec web bin/rails runner "puts ActiveRecord::Base.connection.execute('SELECT * FROM pg_stat_activity').to_a"
```

**Solutions**:

1. **Database connection pool exhausted**
   Increase RAILS_MAX_THREADS or add connection pooling (PgBouncer).

2. **N+1 queries**
   Check Rails logs for repeated queries:
   ```bash
   docker compose -f docker-compose.prod.yml logs web | grep -i "SELECT"
   ```

3. **Insufficient resources**
   ```bash
   top
   htop
   ```
   Solution: Upgrade server or optimize application.

4. **Redis connection issues**
   ```bash
   docker compose -f docker-compose.prod.yml exec redis redis-cli ping
   ```

### High Memory Usage

**Symptom**: Server runs out of memory or swaps heavily.

**Diagnosis**:
```bash
docker stats
free -h
```

**Solutions**:

1. **Reduce Puma workers**
   Lower WEB_CONCURRENCY in .env.

2. **Reduce Sidekiq concurrency**
   Lower SIDEKIQ_CONCURRENCY in .env.

3. **Add swap space**
   ```bash
   sudo fallocate -l 2G /swapfile
   sudo chmod 600 /swapfile
   sudo mkswap /swapfile
   sudo swapon /swapfile
   ```

4. **Restart services periodically**
   Set up cron job to restart weekly:
   ```bash
   0 3 * * 0 cd /home/deploy/apps/the-greatest && docker compose -f docker-compose.prod.yml restart web worker
   ```

## Disk Space Issues

### Disk Space Full

**Symptom**: Server operations fail with "No space left on device".

**Diagnosis**:
```bash
df -h
docker system df
```

**Solutions**:

1. **Clean up Docker resources**
   ```bash
   docker system prune -af
   docker volume prune -f
   ```

2. **Check log files**
   ```bash
   du -sh /var/lib/docker/containers/*
   ```
   Log rotation should prevent this, but check:
   ```bash
   docker inspect the-greatest-web | grep -A 10 LogConfig
   ```

3. **Remove old images**
   ```bash
   docker image prune -a
   ```

4. **Increase disk size**
   Resize volume through Linode dashboard.

### Log Files Growing

**Symptom**: Docker logs consuming excessive disk space.

**Diagnosis**:
```bash
docker ps -q | xargs docker inspect --format='{{.LogPath}}' | xargs ls -lh
```

**Solutions**:

1. **Verify log rotation configured**
   Check docker-compose.prod.yml has logging section:
   ```yaml
   logging:
     driver: json-file
     options:
       max-size: "10m"
       max-file: "3"
   ```

2. **Manually truncate logs**
   ```bash
   truncate -s 0 $(docker inspect --format='{{.LogPath}}' the-greatest-web)
   ```

3. **Restart container to apply log rotation**
   ```bash
   docker compose -f docker-compose.prod.yml restart
   ```

## Network Issues

### Cannot Access Application

**Symptom**: Unable to reach application via domain name.

**Diagnosis**:
```bash
ping thegreatestmusic.org
nslookup thegreatestmusic.org
curl -I http://localhost
```

**Solutions**:

1. **DNS not configured**
   Update DNS A records to point to server IP.

2. **Firewall blocking ports**
   ```bash
   sudo ufw status
   sudo ufw allow 80
   sudo ufw allow 443
   ```

3. **Nginx not listening**
   ```bash
   docker compose -f docker-compose.prod.yml ps nginx
   netstat -tlnp | grep :443
   ```

### Cloudflare Errors

**Symptom**: 520, 521, or 522 errors from Cloudflare.

**Solutions**:

1. **Origin server down**
   Check nginx and web containers are running.

2. **SSL verification failure**
   Ensure SSL mode is "Full" or "Full (strict)" in Cloudflare dashboard.

3. **Cloudflare IP not whitelisted**
   If using firewall, whitelist Cloudflare IPs.

## Application Issues

### Assets Not Loading

**Symptom**: CSS, JavaScript, or images return 404.

**Diagnosis**:
```bash
docker compose -f docker-compose.prod.yml exec web ls -la public/assets
curl https://thegreatestmusic.org/assets/application.css
```

**Solutions**:

1. **Assets not precompiled**
   ```bash
   docker compose -f docker-compose.prod.yml exec web bin/rails assets:precompile
   ```

2. **Wrong asset host**
   Check Rails asset configuration.

3. **Cache-Control headers**
   Check nginx passes through Rails Cache-Control headers.

### Background Jobs Not Processing

**Symptom**: Sidekiq jobs stuck in queue.

**Diagnosis**:
```bash
docker compose -f docker-compose.prod.yml logs worker
docker compose -f docker-compose.prod.yml exec worker ps aux | grep sidekiq
```

**Solutions**:

1. **Worker container not running**
   ```bash
   docker compose -f docker-compose.prod.yml restart worker
   ```

2. **Redis connection failure**
   ```bash
   docker compose -f docker-compose.prod.yml exec worker bin/rails runner "Sidekiq.redis(&:ping)"
   ```

3. **Queue paused**
   Access Sidekiq web UI and check queue status.

### Firebase Auth Not Working

**Symptom**: Users cannot sign in via Firebase.

**Diagnosis**:
```bash
curl https://thegreatestmusic.org/__/auth/handler
docker compose -f docker-compose.prod.yml logs nginx | grep "__/auth"
```

**Solutions**:

1. **Nginx proxy configuration incorrect**
   Verify `/__/auth/` location block in nginx config.

2. **Firebase credentials missing**
   Check FIREBASE_* environment variables.

3. **CORS issues**
   Add Firebase domains to CORS configuration.

## Getting Additional Help

If issues persist:

1. **Check logs thoroughly**
   ```bash
   docker compose -f docker-compose.prod.yml logs --tail 500
   ```

2. **Enable debug logging**
   Set `RAILS_LOG_LEVEL=debug` in .env and restart.

3. **Test individual components**
   Isolate the problem (database, Redis, application, nginx).

4. **Consult documentation**
   - README.md - General deployment guide
   - ENV.md - Environment variables
   - ROLLBACK.md - Recovery procedures

5. **Review recent changes**
   Check git history for recent code changes that may have caused issues.
