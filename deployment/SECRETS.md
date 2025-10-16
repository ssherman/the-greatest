# Secrets Management with SOPS + age

This document explains how to manage production secrets using SOPS (Secrets OPerationS) and age encryption.

## Overview

We use SOPS + age to:
- Keep encrypted secrets committed to git
- Allow multiple maintainers to decrypt/edit secrets
- Automatically decrypt secrets during CI/CD deployment
- Maintain an audit trail of secret changes

**File locations:**
- Encrypted: `secrets/.env.production` (committed to git)
- Decrypted: `.env` on production server only (never committed)
- Local dev: `web-app/.env` (gitignored, never committed)

## Prerequisites

### Install Tools Locally

```bash
# macOS
brew install sops age

# Linux
# Download latest releases from:
# https://github.com/getsops/sops/releases
# https://github.com/FiloSottile/age/releases
```

### Get Your Age Key

Ask a maintainer for:
1. The production age private key (stored in `~/.config/sops/age/production.txt`)
2. Or generate your own and have them add your public key

## Editing Secrets

### Quick Edit (Recommended)

SOPS will automatically decrypt, open your `$EDITOR`, and re-encrypt on save:

```bash
# Make sure your age key is in the right location
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt

# Edit secrets (opens in $EDITOR)
sops secrets/.env.production

# Make your changes, save, and exit
# SOPS automatically re-encrypts the file

# Commit the encrypted file
git add secrets/.env.production
git commit -m "chore(secrets): update DATABASE_URL"
git push
```

### View Secrets Without Editing

```bash
# View entire decrypted file
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt
sops -d secrets/.env.production

# View specific value
sops -d secrets/.env.production | grep POSTGRES_PASSWORD

# Pipe to less for browsing
sops -d secrets/.env.production | less
```

### Manual Decrypt/Edit/Encrypt (Advanced)

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt

# Decrypt to temporary file
sops -d secrets/.env.production > secrets/.env.plain

# Edit with any editor
nano secrets/.env.plain

# Re-encrypt
sops --encrypt secrets/.env.plain > secrets/.env.production

# Delete plaintext
rm secrets/.env.plain

# Commit
git add secrets/.env.production
git commit -m "chore(secrets): update secrets"
```

## Adding a New Secret

### Option 1: Edit existing file

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt
sops secrets/.env.production

# Add your new line:
# NEW_API_KEY=your_secret_value_here

# Save and exit - SOPS re-encrypts automatically
git add secrets/.env.production
git commit -m "chore(secrets): add NEW_API_KEY"
```

### Option 2: Decrypt, modify, re-encrypt

```bash
sops -d secrets/.env.production > temp.env
echo "NEW_API_KEY=your_secret_value" >> temp.env
sops --encrypt temp.env > secrets/.env.production
rm temp.env
```

## Key Management

### Generate New Age Keypair

```bash
# Create age config directory
mkdir -p ~/.config/sops/age

# Generate keypair
age-keygen -o ~/.config/sops/age/production.txt

# View your keys
cat ~/.config/sops/age/production.txt
# Shows: Private key (AGE-SECRET-KEY-...)
#        Public key  (age1...)

# Extract just the public key
age-keygen -y ~/.config/sops/age/production.txt
```

### Add New Maintainer

1. **New maintainer generates their key:**
   ```bash
   age-keygen -o ~/.config/sops/age/keys.txt
   NEW_PUBLIC_KEY=$(age-keygen -y ~/.config/sops/age/keys.txt)
   echo $NEW_PUBLIC_KEY
   # Share this public key: age1...
   ```

2. **Existing maintainer adds the new key:**
   ```bash
   # Edit .sops.yaml and add the new public key
   nano .sops.yaml

   # Example:
   creation_rules:
     - path_regex: secrets/\.env\.production$
       encrypted_regex: '^(?!#).*'
       age:
         - age1dnc82r63zyqtqlet84l2naxhjrdcdrc3gaxp592y69u0pg0m2u3q9j02zf  # bot key
         - age1<NEW_MAINTAINER_PUBLIC_KEY>  # new maintainer
   ```

3. **Re-encrypt with all keys:**
   ```bash
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt
   sops updatekeys secrets/.env.production
   ```

4. **Commit changes:**
   ```bash
   git add .sops.yaml secrets/.env.production
   git commit -m "chore(secrets): add new maintainer key"
   git push
   ```

5. **New maintainer can now decrypt:**
   ```bash
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
   sops -d secrets/.env.production
   ```

### Remove Maintainer Access

1. **Remove their public key from `.sops.yaml`**
2. **Re-encrypt with remaining keys:**
   ```bash
   sops updatekeys secrets/.env.production
   ```
3. **Commit and push**

They will no longer be able to decrypt the file.

### Rotate Production Key

```bash
# Generate new key
age-keygen -o ~/.config/sops/age/production-new.txt
NEW_PUBLIC_KEY=$(age-keygen -y ~/.config/sops/age/production-new.txt)

# Update .sops.yaml with both old and new keys temporarily
# Re-encrypt with both keys
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt
sops updatekeys secrets/.env.production

# Update GitHub Actions secret AGE_PRIVATE_KEY with new private key
# (entire contents of production-new.txt)

# Test deployment works

# Remove old key from .sops.yaml, keep only new key
# Re-encrypt with only new key
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production-new.txt
sops updatekeys secrets/.env.production

# Commit
git add .sops.yaml secrets/.env.production
git commit -m "chore(secrets): rotate production age key"

# Clean up
mv ~/.config/sops/age/production.txt ~/.config/sops/age/production-old.txt
mv ~/.config/sops/age/production-new.txt ~/.config/sops/age/production.txt
```

## Deployment

Secrets are automatically decrypted and deployed by GitHub Actions.

### GitHub Actions Secrets Required

- `AGE_PRIVATE_KEY` - Entire contents of age private key file
- `DEPLOY_SSH_KEY` - SSH private key for deploy user
- `SERVER_WEB_HOST` - Production server hostname or IP

### How Deployment Works

1. GitHub Actions checks out code
2. Installs SOPS
3. Writes `AGE_PRIVATE_KEY` to `~/.config/sops/age/keys.txt`
4. Decrypts `secrets/.env.production` → `.env.decrypted`
5. Rsyncs code to server (excluding encrypted secrets)
6. Writes decrypted `.env` atomically to server with 0600 permissions
7. Pulls Docker images and restarts services
8. Docker Compose auto-loads `.env`

### Manual Deployment with Secrets

If you need to deploy manually:

```bash
# Decrypt secrets locally
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt
sops -d secrets/.env.production > .env.decrypted

# SCP to server
scp .env.decrypted deploy@server:/home/deploy/apps/the-greatest/.env.new
ssh deploy@server "cd /home/deploy/apps/the-greatest && \
  mv .env.new .env && \
  chmod 600 .env"

# Clean up local decrypted file
rm .env.decrypted

# Deploy application
ssh deploy@server "cd /home/deploy/apps/the-greatest && \
  docker compose -f docker-compose.prod.yml pull && \
  docker compose -f docker-compose.prod.yml up -d"
```

## Verification

### Verify Encryption

```bash
# Encrypted file should show JSON structure with encrypted data
cat secrets/.env.production | head -10

# Should see:
# {
#   "data": "ENC[AES256_GCM,data:...
#   "sops": {
#     "age": [...]
```

### Verify Decryption

```bash
# Should show plaintext environment variables
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt
sops -d secrets/.env.production | head -5

# Should see:
# RAILS_ENV=production
# RAILS_MASTER_KEY=abc123...
# SECRET_KEY_BASE=xyz789...
```

### Verify on Server

```bash
ssh deploy@server

# Check .env file exists with correct permissions
ls -la /home/deploy/apps/the-greatest/.env
# Should show: -rw------- 1 deploy deploy

# Check Docker Compose can read it
cd /home/deploy/apps/the-greatest
docker compose -f docker-compose.prod.yml config | grep RAILS_ENV
# Should show: RAILS_ENV=production

# Check running containers have the env vars
docker compose -f docker-compose.prod.yml exec web env | grep POSTGRES_HOST
# Should show your actual database host
```

## Troubleshooting

### "no key could decrypt the data"

**Problem:** SOPS can't find the right age key.

**Solution:**
```bash
# Make sure SOPS_AGE_KEY_FILE points to your key
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt

# Verify the key file exists
cat $SOPS_AGE_KEY_FILE

# Verify your public key matches one in .sops.yaml
age-keygen -y $SOPS_AGE_KEY_FILE
cat .sops.yaml | grep age1
```

### "MAC mismatch"

**Problem:** File was corrupted or edited without SOPS.

**Solution:**
```bash
# Restore from git history
git checkout HEAD secrets/.env.production

# Or get from another maintainer
```

### "Failed to get the data key"

**Problem:** Your key is not in the file's allowed keys.

**Solution:** Ask a maintainer to add your public key (see "Add New Maintainer" above).

### Secrets not loading in containers

**Problem:** Environment variables not available in Docker containers.

**Diagnosis:**
```bash
# Check .env exists on server
ssh deploy@server ls -la /home/deploy/apps/the-greatest/.env

# Check Docker Compose can read it
ssh deploy@server "cd /home/deploy/apps/the-greatest && \
  docker compose -f docker-compose.prod.yml config | head -20"
```

**Solution:**
- Ensure `.env` is in the same directory as `docker-compose.prod.yml`
- Ensure `.env` has proper permissions (600)
- Restart services: `docker compose -f docker-compose.prod.yml up -d`

## Security Best Practices

### DO

- ✅ Always use `sops` command to edit encrypted files
- ✅ Keep age private keys secure (never commit)
- ✅ Use separate keys per environment (prod, staging)
- ✅ Rotate keys when maintainers leave
- ✅ Commit encrypted files to git
- ✅ Use `umask 077` when creating decrypted files
- ✅ Delete decrypted files after use
- ✅ Use strong passwords/tokens for actual secrets

### DON'T

- ❌ Never commit `.env` files (decrypted)
- ❌ Never commit age private keys
- ❌ Never edit encrypted files manually
- ❌ Never share private keys via email/slack
- ❌ Never leave decrypted files on disk
- ❌ Never use weak secrets because "they're encrypted anyway"
- ❌ Never skip verifying after encryption

## Common Tasks Cheat Sheet

```bash
# Set this once per terminal session
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt

# Edit secrets
sops secrets/.env.production

# View secrets
sops -d secrets/.env.production

# View specific value
sops -d secrets/.env.production | grep POSTGRES_PASSWORD

# Add maintainer (after getting their public key)
# 1. Edit .sops.yaml, add their key
# 2. Re-encrypt
sops updatekeys secrets/.env.production

# Verify encryption
cat secrets/.env.production | jq .sops.age

# Test decryption
sops -d secrets/.env.production > /dev/null && echo "OK" || echo "FAIL"
```

## Related Documentation

- `README.md` - General deployment overview
- `ENV.md` - Environment variable reference
- `MANUAL_DEPLOY.md` - Manual deployment procedures
- `TROUBLESHOOTING.md` - Deployment troubleshooting

## External Resources

- [SOPS Documentation](https://github.com/getsops/sops)
- [age Documentation](https://github.com/FiloSottile/age)
- [SOPS with age Tutorial](https://devops.stackexchange.com/questions/15843/how-to-use-sops-with-age-and-git)
