# Cloud-Init Full Deploy Automation

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2026-01-19
- **Started**:
- **Completed**:
- **Developer**:

## Overview
Automate full server deployment via cloud-init so a fresh Linode instance comes up fully operational without manual intervention. This includes:
1. Cloud-init decrypts secrets using SOPS/age, generates SSL certificates, and starts all Docker containers
2. Terraform manages Cloudflare DNS A records to automatically point domains to the new server IP

**Non-goals**: Changing the GitHub Actions deploy workflow (it remains for code updates post-provisioning).

## Context & Links
- Related: Terraform infrastructure in `deployment/terraform/`
- Source files (authoritative):
  - `deployment/terraform/variables.tf`
  - `deployment/terraform/web-cloud-init.yaml`
  - `deployment/terraform/linode-web.tf`
  - `deployment/scripts/generate-certs.sh`
- GitHub Actions deploy: `.github/workflows/deploy-production.yml`

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes.

### Terraform Variables (new)
| Variable | Type | Sensitive | Description |
|----------|------|-----------|-------------|
| `age_private_key` | string | yes | SOPS age private key for decrypting secrets |
| `cloudflare_api_token` | string | yes | Cloudflare API token for DNS management |
| `cloudflare_zone_id_music` | string | no | Zone ID for thegreatestmusic.org |
| `cloudflare_zone_id_games` | string | no | Zone ID for thegreatest.games |
| `cloudflare_zone_id_movies` | string | no | Zone ID for thegreatestmovies.org |

### Terraform Resources (new)
| Resource | Purpose |
|----------|---------|
| `cloudflare_record.music_root` | A record for thegreatestmusic.org → Linode IP |
| `cloudflare_record.music_www` | A record for www.thegreatestmusic.org → Linode IP |
| `cloudflare_record.games_root` | A record for thegreatest.games → Linode IP |
| `cloudflare_record.games_www` | A record for www.thegreatest.games → Linode IP |
| `cloudflare_record.movies_root` | A record for thegreatestmovies.org → Linode IP |
| `cloudflare_record.movies_www` | A record for www.thegreatestmovies.org → Linode IP |

> Uses Cloudflare Terraform provider: `cloudflare/cloudflare`

### Behaviors (pre/postconditions)

**Preconditions**:
- Linode API token valid
- `age_private_key` provided in `terraform.tfvars`
- `cloudflare_api_token` provided in `terraform.tfvars`
- Cloudflare zone IDs provided for all 3 domains
- `secrets/.env.production` exists in repo (encrypted)
- Cloudflare API token in encrypted secrets has DNS edit permissions (for SSL cert generation)

**Postconditions**:
- Server provisioned with Docker installed
- Cloudflare A records updated to point all domains to new Linode IP
- Repo cloned to `/home/deploy/apps/the-greatest`
- Secrets decrypted to `/home/deploy/apps/the-greatest/.env`
- SSL certificates generated in `/etc/letsencrypt/live/`
- All containers running: redis, web, worker, nginx

**Edge cases & failure modes**:
- If cert generation fails (Cloudflare API issue), containers should still start but nginx will fail — acceptable, manual fix possible
- If secrets decryption fails, abort deploy and log error
- Network not ready on first clone attempt — existing retry logic handles this

### Non-Functionals
- Age key written to temp file with `chmod 600`, deleted after use
- No secrets logged to cloud-init output
- Total cloud-init runtime: ~3-5 minutes (acceptable)

## Acceptance Criteria
- [ ] `terraform apply` on fresh infrastructure results in fully running application
- [ ] Cloudflare A records automatically updated to new server IP
- [ ] `nslookup` (with proxy disabled) or Cloudflare dashboard shows correct IP
- [ ] `docker ps` shows all 4 containers healthy (redis, web, worker, nginx)
- [ ] SSL certificates exist in `/etc/letsencrypt/live/thegreatestmusic.org/`
- [ ] `.env` file exists with decrypted secrets (mode 600)
- [ ] Age key is not persisted on disk after cloud-init completes
- [ ] `terraform.tfvars.example` documents all new variables (age key, Cloudflare token, zone IDs)

### Golden Examples

**Input** (terraform.tfvars):
```text
age_private_key         = "AGE-SECRET-KEY-1QQQQQQ..."
cloudflare_api_token    = "xxxxxxxxxxxxxxxxxxxx"
cloudflare_zone_id_music  = "abc123..."
cloudflare_zone_id_games  = "def456..."
cloudflare_zone_id_movies = "ghi789..."
# ... other existing vars
```

**Output** (cloud-init-output.log):
```text
Decrypting secrets with SOPS...
✓ Secrets decrypted to .env
Generating SSL certificates...
✓ Certificate for thegreatestmusic.org generated successfully
✓ Certificate for thegreatest.games generated successfully
✓ Certificate for thegreatestmovies.org generated successfully
Starting Docker containers...
✓ All containers started
Cloud-init v. X.X finished at ...
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Keep secrets handling secure (temp files, proper permissions, cleanup).

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Manual testing on fresh `terraform apply` demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-analyzer → review current cloud-init and deploy workflow patterns
2) web-search-researcher → cloud-init best practices for secrets handling (if needed)
3) technical-writer → update `deployment/terraform/README.md`

### Test Seed / Fixtures
- Existing `secrets/.env.production` (encrypted) in repo
- Valid age key for testing (do not commit)

---

## Implementation Notes (living)
- Approach taken:
- Important decisions:

### Key Files Touched (paths only)
- `deployment/terraform/variables.tf`
- `deployment/terraform/web-cloud-init.yaml`
- `deployment/terraform/linode-web.tf`
- `deployment/terraform/cloudflare-dns.tf` (new)
- `deployment/terraform/terraform.tfvars.example`
- `deployment/terraform/README.md`

### Challenges & Resolutions
-

### Deviations From Plan
-

## Acceptance Results
- Date, verifier, artifacts (screenshots/links):

## Future Improvements
- Consider adding health check that waits for all containers before cloud-init reports success
- Add Slack/webhook notification on successful deploy

## Related PRs
- #

## Documentation Updated
- [ ] `deployment/terraform/README.md`
- [ ] Class docs (N/A)
