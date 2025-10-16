# 049 - SOPS + age Secrets Management

## Status
- **Status**: Completed (Pending Manual Testing)
- **Priority**: High
- **Created**: 2025-10-12
- **Started**: 2025-10-12
- **Completed**: 2025-10-15
- **Developer**: Shane Sherman

## Overview
Implement production/staging secrets management using SOPS + age with GitHub Actions and Docker Compose. Keep encrypted env files in git; decrypt in CI and install atomically on the server before docker compose up -d.

## Context
Currently, production secrets would need to be managed manually on the server or through GitHub Actions secrets. This approach is not scalable, not auditable, and makes it difficult for multiple maintainers to manage secrets. SOPS + age provides:
- Git-friendly encrypted secrets (keys visible, values encrypted)
- Multiple maintainer access via age public keys
- Auditability (encrypted secrets committed, changes tracked)
- CI/CD integration (decrypt in GitHub Actions)
- Atomic deployment with proper permissions

## Requirements

### Core Functionality
- [x] Encrypted secrets committed to repo at `secrets/.env.production`
- [x] `.sops.yaml` configuration at repo root
- [x] age keypair generated for production deployment
- [x] GitHub Actions secret `AGE_PRIVATE_KEY` configured
- [x] Deploy workflow decrypts and installs `./.env` on server with mode 0600
- [x] All services load secrets from root `./.env` (auto-loaded by Docker Compose)
- [x] No plaintext secrets in repo, Terraform, cloud-init, or image layers

### File Structure
```
the-greatest/
├── .sops.yaml                    # SOPS configuration
├── secrets/
│   ├── .env.production          # encrypted, committed
│   ├── .env.staging             # encrypted, committed (optional)
│   └── .gitkeep
├── .env                          # decrypted, gitignored (production server only)
├── .env.example                 # template for local dev
├── web-app/
│   └── .env                     # gitignored (local dev only)
├── docker-compose.prod.yml      # auto-loads ./.env
└── .gitignore                   # includes .env, web-app/.env, secrets/*.decrypted
```

### Secrets to Migrate
From current setup, these secrets need to be in `secrets/.env.production`:

**Rails:**
- `RAILS_ENV=production`
- `RAILS_MASTER_KEY=<secret>`
- `SECRET_KEY_BASE=<secret>`

**Database:**
- `POSTGRES_HOST=<host>`
- `POSTGRES_PORT=5432`
- `POSTGRES_DATABASE=the_greatest_production`
- `POSTGRES_USER=the_greatest`
- `POSTGRES_PASSWORD=<secret>`

**Redis:**
- `REDIS_URL=redis://redis:6379/1`

**OpenSearch:**
- `OPENSEARCH_URL=<url>`

**SSL Certificates:**
- `CLOUDFLARE_API_TOKEN=<secret>`

**Firebase (if using):**
- `FIREBASE_PROJECT_ID=<id>`
- `FIREBASE_API_KEY=<key>`

**Performance (optional):**
- `RAILS_MAX_THREADS=50`
- `WEB_CONCURRENCY=2`
- `SIDEKIQ_CONCURRENCY=10`

### Non-Secrets (Keep in docker-compose.prod.yml)
These can remain in the `environment:` blocks since they're not sensitive:
- `NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/conf.d`
- `WEB_HOST=web`
- `WEB_PORT=80`
- `CERT_PATH=/etc/letsencrypt/live`
- `KEY_PATH=/etc/letsencrypt/live`

## Technical Approach

### 1. SOPS Configuration

Create `.sops.yaml`:
```yaml
creation_rules:
  - path_regex: secrets/.*\.env\.production$
    encrypted_regex: '^(?!#).*'
    age: "age1<PRODUCTION_PUBLIC_KEY>"

  - path_regex: secrets/.*\.env\.staging$
    encrypted_regex: '^(?!#).*'
    age: "age1<STAGING_PUBLIC_KEY>"
```

### 2. Age Key Generation

Generate keypair locally:
```bash
# Install age
brew install age  # or appropriate package manager

# Generate production key
age-keygen -o ~/.config/sops/age/production.txt

# Extract public key
age-keygen -y ~/.config/sops/age/production.txt
# Output: age1<public_key>
```

Store private key in GitHub Actions secret `AGE_PRIVATE_KEY`.
Add public key to `.sops.yaml`.

### 3. Create Encrypted Secrets File

Create `secrets/.env.production` with all production secrets:
```bash
# Create directory
mkdir -p secrets

# Create plaintext template
cat > secrets/.env.production.plain << 'EOF'
# Rails
RAILS_ENV=production
RAILS_MASTER_KEY=your_master_key_here
SECRET_KEY_BASE=your_secret_key_base_here

# Database
POSTGRES_HOST=postgresql.example.com
POSTGRES_PORT=5432
POSTGRES_DATABASE=the_greatest_production
POSTGRES_USER=the_greatest
POSTGRES_PASSWORD=your_postgres_password

# Redis
REDIS_URL=redis://redis:6379/1

# OpenSearch
OPENSEARCH_URL=https://opensearch.example.com:9200

# SSL Certificates
CLOUDFLARE_API_TOKEN=your_cloudflare_token

# Firebase
FIREBASE_PROJECT_ID=thegreatestmusic-org
FIREBASE_API_KEY=your_firebase_api_key

# Performance
RAILS_MAX_THREADS=50
WEB_CONCURRENCY=2
SIDEKIQ_CONCURRENCY=10
EOF

# Encrypt with SOPS
SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt \
  sops --encrypt secrets/.env.production.plain > secrets/.env.production

# Verify keys are visible, values encrypted
cat secrets/.env.production

# Delete plaintext
rm secrets/.env.production.plain
```

### 4. Update .gitignore

Add to `.gitignore`:
```
# Environment files
.env
web-app/.env

# SOPS decrypted files
secrets/*.decrypted
secrets/*.plain
secrets/*.tmp
```

### 5. Update docker-compose.prod.yml

Since Docker Compose auto-loads `./.env`, we can simplify the environment blocks to only include non-secret configuration:

```yaml
services:
  web:
    image: ghcr.io/ssherman/the-greatest:latest
    container_name: the-greatest-web
    environment:
      # Secrets loaded from ./.env automatically
      # Keep only structural config here if needed
    volumes:
      - rails-storage:/rails/storage
      - rails-log:/rails/log
    # ... rest of config

  worker:
    image: ghcr.io/ssherman/the-greatest:latest
    container_name: the-greatest-worker
    command: bundle exec sidekiq
    environment:
      # Secrets loaded from ./.env automatically
    # ... rest of config

  nginx:
    environment:
      # Keep nginx-specific config
      - NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/conf.d
      - WEB_HOST=web
      - WEB_PORT=80
      - CERT_PATH=/etc/letsencrypt/live
      - KEY_PATH=/etc/letsencrypt/live
    # ... rest of config
```

### 6. Update GitHub Actions Deploy Workflow

Create or update `.github/workflows/deploy-web.yml`:

```yaml
name: Deploy to Production

on:
  repository_dispatch:
    types: [image-built-event]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install SOPS
        run: |
          curl -fsSL https://github.com/getsops/sops/releases/latest/download/sops-v3.8.1.linux.amd64 \
            -o /usr/local/bin/sops
          chmod +x /usr/local/bin/sops

      - name: Decrypt secrets
        env:
          SOPS_AGE_KEY: ${{ secrets.AGE_PRIVATE_KEY }}
        run: |
          mkdir -p ~/.config/sops/age
          printf "%s" "$SOPS_AGE_KEY" > ~/.config/sops/age/keys.txt
          export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
          sops -d secrets/.env.production > .env.decrypted

      - name: Deploy to server
        env:
          SSH_PRIVATE_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
          SERVER_HOST: ${{ secrets.SERVER_HOST }}
          SERVER_USER: deploy
        run: |
          # Setup SSH
          mkdir -p ~/.ssh
          echo "$SSH_PRIVATE_KEY" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          ssh-keyscan -H $SERVER_HOST >> ~/.ssh/known_hosts

          # Rsync code (exclude secrets directory)
          rsync -avz --delete \
            --exclude='.git' \
            --exclude='secrets/' \
            --exclude='.env*' \
            -e "ssh -i ~/.ssh/deploy_key" \
            ./ $SERVER_USER@$SERVER_HOST:/home/deploy/apps/the-greatest/

          # Deploy secrets atomically
          cat .env.decrypted | ssh -i ~/.ssh/deploy_key $SERVER_USER@$SERVER_HOST \
            "umask 077 && cat > /home/deploy/apps/the-greatest/.env.new && \
             mv /home/deploy/apps/the-greatest/.env.new /home/deploy/apps/the-greatest/.env && \
             chmod 600 /home/deploy/apps/the-greatest/.env"

          # Deploy application
          ssh -i ~/.ssh/deploy_key $SERVER_USER@$SERVER_HOST << 'ENDSSH'
            cd /home/deploy/apps/the-greatest
            docker compose -f docker-compose.prod.yml pull
            docker compose -f docker-compose.prod.yml up -d --remove-orphans
            docker system prune -f
          ENDSSH

      - name: Verify deployment
        env:
          SSH_PRIVATE_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
          SERVER_HOST: ${{ secrets.SERVER_HOST }}
        run: |
          ssh -i ~/.ssh/deploy_key deploy@$SERVER_HOST \
            "docker compose -f /home/deploy/apps/the-greatest/docker-compose.prod.yml ps"
```

### 7. Update Terraform/Cloud-init

Ensure secrets directory exists in `deployment/terraform/web-cloud-init.yaml`:

```yaml
runcmd:
  # ... existing commands

  # Create secrets directory
  - mkdir -p /home/deploy/apps/the-greatest/secrets
  - chown -R deploy:deploy /home/deploy/apps/the-greatest
  - chmod 750 /home/deploy/apps/the-greatest/secrets
```

### 8. Local Development Setup

Create `.env.example` for local developers:
```bash
# Copy this to web-app/.env for local development
# DO NOT commit web-app/.env

# Rails
RAILS_ENV=development
RAILS_MASTER_KEY=get_from_maintainer

# Database (local Docker)
POSTGRES_HOST=localhost
POSTGRES_PORT=6543
POSTGRES_DATABASE=the_greatest_development
POSTGRES_USER=postgres
POSTGRES_PASSWORD=your_local_password

# Redis (local Docker)
REDIS_URL=redis://localhost:6379/1

# OpenSearch (local Docker)
OPENSEARCH_URL=http://localhost:9200
```

## Editing Secrets (Maintainer Workflow)

### Edit Production Secrets
```bash
# Edit secrets (SOPS opens $EDITOR, re-encrypts on save)
SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt \
  sops secrets/.env.production

# Verify encryption
cat secrets/.env.production | head -5

# Commit
git add secrets/.env.production
git commit -m "chore(secrets): update production env"
git push
```

### View Decrypted Secrets (local testing)
```bash
# View decrypted without editing
SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt \
  sops -d secrets/.env.production | grep DATABASE_URL
```

### Add New Maintainer
```bash
# New maintainer generates their key
age-keygen -o ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt
# Shares public key: age1<their_public_key>

# Add to .sops.yaml
# Then re-encrypt for all keys:
SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt \
  sops updatekeys secrets/.env.production

# Commit
git add .sops.yaml secrets/.env.production
git commit -m "chore(secrets): add maintainer key"
```

## Rotation Procedure

### Rotate Age Key
```bash
# Generate new key
age-keygen -o ~/.config/sops/age/production-new.txt
NEW_PUBLIC_KEY=$(age-keygen -y ~/.config/sops/age/production-new.txt)

# Update .sops.yaml with new public key
# Re-encrypt with both old and new keys
SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt \
  sops updatekeys secrets/.env.production

# Update GitHub Actions secret AGE_PRIVATE_KEY with new private key
# Test deployment

# Remove old key from .sops.yaml
# Re-encrypt with only new key
SOPS_AGE_KEY_FILE=~/.config/sops/age/production-new.txt \
  sops updatekeys secrets/.env.production
```

### Rotate Individual Secrets
```bash
# Edit secrets file
SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt \
  sops secrets/.env.production

# Update the specific secret value
# Save (SOPS re-encrypts automatically)
# Commit and deploy
```

## Testing & Verification

### Local Testing
```bash
# Verify encryption
cat secrets/.env.production | head -10
# Should show encrypted values

# Verify decryption
SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt \
  sops -d secrets/.env.production | grep -E 'POSTGRES_PASSWORD|RAILS_MASTER_KEY'
# Should show plaintext values
```

### Server Testing (after deployment)
```bash
ssh deploy@server

# Verify .env exists with correct permissions
ls -la /home/deploy/apps/the-greatest/.env
# Should show: -rw------- 1 deploy deploy <size> <date> .env

# Verify secrets loaded
cd /home/deploy/apps/the-greatest
docker compose -f docker-compose.prod.yml config | grep POSTGRES_PASSWORD
# Should show the secret value (only visible on server)

# Verify services running
docker compose -f docker-compose.prod.yml ps
# All services should be Up and healthy

# Test Rails can access secrets
docker compose -f docker-compose.prod.yml exec web bin/rails runner "puts ENV['POSTGRES_PASSWORD'].present?"
# Should output: true
```

## Security Considerations

### Key Management
- Private keys never committed to repo
- Private keys stored only in GitHub Actions secrets and maintainer local machines
- Use separate keys per environment (production, staging)
- Regular key rotation (annually or when maintainer leaves)

### File Permissions
- Encrypted files: 644 (readable by all, committed to git)
- Decrypted files on server: 600 (readable only by deploy user)
- Secrets directory: 750 (deploy user + group only)

### CI/CD Security
- Decrypted secrets never logged
- Decrypted files deleted after deployment
- SSH keys properly secured (600 permissions)
- Use `--exclude` in rsync to prevent accidental secret transfer

### Audit Trail
- All secret changes tracked in git (encrypted)
- Git history shows who changed secrets and when
- Diff-friendly format (keys visible, only values encrypted)

## Acceptance Criteria

- [x] `.sops.yaml` configured with age encryption rules
- [x] Production age keypair generated and secured
- [x] `secrets/.env.production` created, encrypted, and committed
- [x] `.gitignore` updated to exclude decrypted files
- [x] `docker-compose.prod.yml` simplified to use auto-loaded `.env`
- [x] GitHub Actions secret `AGE_PRIVATE_KEY` configured
- [x] Deploy workflow updated to decrypt and install secrets
- [x] Terraform/cloud-init creates secrets directory
- [ ] `.env.example` created for local development (optional - not needed yet)
- [ ] Documentation updated (README, ENV.md, new SECRETS.md) (deferred)
- [ ] Successful deployment proves services load secrets correctly (pending manual testing)
- [x] No plaintext secrets remain in repo, Terraform, or cloud-init
- [x] Maintainer can edit secrets via `sops secrets/.env.production`

## Documentation Updates Required

### New Files
- [ ] `deployment/SECRETS.md` - Comprehensive secrets management guide
  - How to install SOPS and age
  - How to generate age keys
  - How to edit secrets
  - How to add/remove maintainers
  - How to rotate keys
  - Troubleshooting

### Updates to Existing Files
- [ ] `deployment/README.md` - Add secrets management section
- [ ] `deployment/ENV.md` - Update to reference encrypted secrets
- [ ] `deployment/MANUAL_DEPLOY.md` - Add SOPS setup steps
- [ ] Root `README.md` - Add link to secrets documentation
- [ ] `.env.example` - Template for local development

## Dependencies
- SOPS binary (installed in CI and locally)
- age binary (installed locally for key generation)
- GitHub Actions secrets: `AGE_PRIVATE_KEY`, `DEPLOY_SSH_KEY`, `SERVER_HOST`
- Existing deployment infrastructure (048-production-deployment-infrastructure.md)

## Risks & Mitigations

### Risk: Lost Age Private Key
**Impact**: Cannot decrypt secrets, cannot deploy
**Mitigation**:
- Store encrypted backup of private key in team password manager
- Multiple maintainers with separate keys in `.sops.yaml`
- Document recovery procedure

### Risk: Secrets Leaked in CI Logs
**Impact**: Sensitive data exposed
**Mitigation**:
- Never echo decrypted files in CI
- Use `set +x` when handling secrets
- Delete decrypted files after deployment
- Review GitHub Actions logs before making workflow public

### Risk: Wrong Permissions on Server
**Impact**: Other users could read secrets
**Mitigation**:
- Use `umask 077` before creating files
- Explicitly `chmod 600` after deployment
- Verify permissions in deployment script
- Add verification step in CI

### Risk: Secrets Committed Unencrypted
**Impact**: Plaintext secrets in git history
**Mitigation**:
- Pre-commit hook to check for plaintext secrets
- `.gitignore` includes all decrypted patterns
- Code review process
- Regular secret scanning (GitHub Advanced Security)

## Related Tasks
- 048-production-deployment-infrastructure.md (prerequisite)
- Future: GitHub Actions for build workflow (if not exists)
- Future: Staging environment setup

## Success Metrics
- Zero plaintext secrets in repository
- All maintainers can edit secrets independently
- Deployment succeeds with encrypted secrets
- Secrets properly loaded in all containers
- Audit trail of secret changes in git history
- Recovery procedures documented and tested

---

## Implementation Notes

### Completed Steps

1. **SOPS Configuration** (2025-10-12 - COMPLETED)
   - Created `.sops.yaml` at repo root with age encryption rules
   - Configured for both production and staging environments
   - Used `encrypted_regex: '^(?!#).*'` to keep comments readable
   - Public key: `age1dnc82r63zyqtqlet84l2naxhjrdcdrc3gaxp592y69u0pg0m2u3q9j02zf`

2. **Age Keypair Generation** (2025-10-12 - COMPLETED)
   - Generated production keypair using `age-keygen`
   - Private key stored in GitHub Actions secret `AGE_PRIVATE_KEY`
   - Public key added to `.sops.yaml` configuration
   - Same key used for both production and staging (can be separated later if needed)

3. **Encrypted Secrets File** (2025-10-12 - COMPLETED)
   - Created `secrets/.env.production` with all production secrets
   - Encrypted using SOPS with age encryption
   - Committed encrypted file to repository
   - Verified keys are visible in plaintext, values are encrypted
   - Includes: Rails secrets, database credentials, Redis URL, OpenSearch URL, Cloudflare API token, Firebase config, performance tuning

4. **Gitignore Updates** (2025-10-12 - COMPLETED)
   - Added `.env` and `web-app/.env` to gitignore (root level)
   - Added `secrets/*.decrypted`, `secrets/*.plain`, `secrets/*.tmp` patterns
   - Prevents accidental commit of decrypted secrets

5. **Docker Compose Configuration** (2025-10-12 - COMPLETED)
   - Updated `docker-compose.prod.yml` to use `env_file: .env` for web and worker services
   - Leverages Docker Compose's automatic `.env` loading from project root
   - Kept non-secret nginx environment variables in explicit `environment:` blocks
   - Cleaner configuration with secrets separated from structural config

6. **GitHub Actions Deployment Workflow** (2025-10-12 - COMPLETED)
   - Updated `.github/workflows/deploy-production.yml` to decrypt secrets on server
   - Workflow receives `AGE_PRIVATE_KEY` as GitHub Actions secret
   - Creates temporary age key file in `~/.config/sops/age/keys.txt`
   - Decrypts `secrets/.env.production` to `.env` with atomic write (via `.env.new`)
   - Sets proper permissions: `chmod 600 .env`
   - Cleans up age key file after decryption
   - Secrets deployed before docker compose up, ensuring containers have access

7. **Cloud-init Updates** (2025-10-12 - COMPLETED)
   - Updated `deployment/terraform/web-cloud-init.yaml` to install SOPS binary
   - Downloads SOPS v3.11.0 and installs to `/usr/local/bin/sops`
   - Creates secrets directory with proper permissions: `install -d -m 0750 -o deploy -g deploy /home/deploy/apps/the-greatest/secrets`
   - Installs `age` package via apt for age encryption support
   - All prerequisites in place for SOPS decryption on server

### Approach Taken

The implementation followed the planned approach with a streamlined deployment workflow:

1. **Server-side decryption**: Rather than using rsync from CI to transfer decrypted secrets, we decrypt on the server using the age private key passed via SSH environment variable
2. **Atomic file operations**: Used `.env.new` intermediate file with `mv` for atomic replacement
3. **Security-first**: Proper umask, file permissions, and key cleanup throughout
4. **Docker Compose native**: Leveraged built-in `env_file` directive instead of explicit environment variables

### Key Files Changed

- `.sops.yaml` - Created with age encryption rules
- `secrets/.env.production` - Created and encrypted with production secrets
- `.gitignore` - Added patterns to exclude decrypted files
- `docker-compose.prod.yml` - Added `env_file: .env` to web and worker services
- `.github/workflows/deploy-production.yml` - Added SOPS decryption steps
- `deployment/terraform/web-cloud-init.yaml` - Added SOPS installation and secrets directory creation

### Challenges Encountered

None during implementation - the approach worked as designed.

### Deviations from Plan

**Simplified Deployment Approach**:
- **Planned**: Use separate "Install SOPS" step in GitHub Actions, rsync decrypted file to server
- **Actual**: Decrypt on server using SSH-passed age key, avoiding decrypted secrets on CI runner filesystem
- **Reason**: More secure (secrets never touch CI runner disk), simpler workflow, fewer moving parts

**Cloud-init SOPS Installation**:
- **Planned**: Install SOPS via package manager
- **Actual**: Direct binary download from GitHub releases
- **Reason**: More reliable, specific version control, no dependency on package repos

**Same Age Key for Staging and Production**:
- **Planned**: Separate keys per environment
- **Actual**: Single key for both (easily separable later)
- **Reason**: Simpler for MVP, can rotate and separate when staging environment is actually created

### Testing Approach

**Local Verification** (Completed):
```bash
# Verified encryption
cat secrets/.env.production  # Keys visible, values encrypted

# Verified SOPS can decrypt (requires private key)
SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt \
  sops -d secrets/.env.production  # Shows plaintext values

# Verified .gitignore patterns working
git status  # No decrypted files shown as untracked
```

**Server Testing** (Pending Manual Deployment):
1. Deploy via GitHub Actions
2. SSH to server and verify:
   - `.env` file exists with `chmod 600` permissions
   - Docker Compose can read secrets: `docker compose config | grep POSTGRES_PASSWORD`
   - Services start successfully
   - Rails can access environment variables
   - No plaintext secrets in logs

### Security Considerations Implemented

✅ **Key Management**:
- Private key only in GitHub Actions secrets and local machine
- Never committed to repo
- Automatically cleaned up after use in workflow

✅ **File Permissions**:
- Encrypted files: 644 (committed to git)
- Decrypted `.env` on server: 600 (deploy user only)
- Secrets directory: 750 (deploy user + group)

✅ **CI/CD Security**:
- Age key written with `chmod 600` before use
- Age key deleted after decryption
- Secrets file written atomically with proper umask
- No secrets echoed in logs

✅ **Audit Trail**:
- All secret changes tracked in git (encrypted)
- Git history shows who modified secrets and when
- Diff-friendly format for code review

### Performance Considerations

- SOPS decryption adds ~1 second to deployment time (negligible)
- Age encryption/decryption is fast and lightweight
- No impact on container startup time (secrets loaded before compose up)

### Future Improvements

- Create separate age keys for staging vs production environments
- Add pre-commit hook to verify no plaintext secrets committed
- Implement automated secret rotation procedure
- Add Slack notifications for secret changes
- Create comprehensive `deployment/SECRETS.md` documentation
- Add `.env.example` template for local development
- Implement emergency secret recovery procedure documentation

### Lessons Learned

1. **Server-side decryption is simpler and more secure** than CI-side decryption + rsync
2. **Docker Compose `env_file` directive** is cleaner than explicit environment variables
3. **Age + SOPS is straightforward** - no complex key management needed
4. **Atomic file operations** (`mv` instead of direct write) prevent partial reads
5. **SOPS encrypted files are git-friendly** - can diff and code review secret changes

### Related PRs

- Will be merged in deployment branch (no separate PR for this feature)

### Documentation Updated

- [x] This task file (049-sops-secrets-management.md) with complete implementation notes
- [ ] `deployment/SECRETS.md` - Deferred until needed by additional maintainers
- [ ] `deployment/README.md` - Deferred until full deployment documentation written
- [ ] `deployment/ENV.md` - Deferred until full deployment documentation written

### Manual Testing Required

Before marking this task as fully complete:
1. Trigger GitHub Actions deployment workflow
2. Verify secrets are decrypted and written to server
3. Verify Docker containers start with correct environment variables
4. Verify Rails application can access database using decrypted credentials
5. Verify no plaintext secrets appear in logs or CI output
