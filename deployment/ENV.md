# Environment Variables Reference

This document lists all environment variables required for production deployment of The Greatest application.

## Required Variables

### Rails Configuration

#### RAILS_ENV
- **Description**: Rails environment setting
- **Required**: Yes
- **Value**: `production`
- **Used By**: web, worker

#### RAILS_MASTER_KEY
- **Description**: Master key for encrypted credentials
- **Required**: Yes
- **Location**: Generated via `rails credentials:edit`
- **Used By**: web, worker
- **Security**: Never commit this value

#### SECRET_KEY_BASE
- **Description**: Secret key for Rails session verification
- **Required**: Yes
- **Generate**: `rails secret`
- **Used By**: web, worker
- **Security**: Never commit this value

### Database Configuration

#### POSTGRES_HOST
- **Description**: PostgreSQL server hostname or IP
- **Required**: Yes
- **Example**: `postgresql.example.com` or `10.0.0.5`
- **Used By**: web, worker

#### POSTGRES_PORT
- **Description**: PostgreSQL server port
- **Required**: No
- **Default**: `5432`
- **Used By**: web, worker

#### POSTGRES_DATABASE
- **Description**: PostgreSQL database name
- **Required**: Yes
- **Example**: `the_greatest_production`
- **Used By**: web, worker

#### POSTGRES_USER
- **Description**: PostgreSQL username
- **Required**: Yes
- **Example**: `the_greatest`
- **Used By**: web, worker

#### POSTGRES_PASSWORD
- **Description**: PostgreSQL password
- **Required**: Yes
- **Used By**: web, worker
- **Security**: Never commit this value

### Redis Configuration

#### REDIS_URL
- **Description**: Redis connection URL
- **Required**: No
- **Default**: `redis://redis:6379/1`
- **Format**: `redis://host:port/db`
- **Used By**: web, worker

### OpenSearch Configuration

#### OPENSEARCH_URL
- **Description**: OpenSearch cluster URL
- **Required**: Yes
- **Example**: `https://opensearch.example.com:9200`
- **Used By**: web, worker

### SSL Certificate Configuration

#### CLOUDFLARE_API_TOKEN
- **Description**: Cloudflare API token with DNS edit permissions
- **Required**: Yes (for certificate generation/renewal)
- **Used By**: generate-certs.sh, renew-certs.sh
- **Permissions**: Zone:DNS:Edit
- **Security**: Never commit this value

### Nginx Template Variables

These variables are used by nginx's built-in template system for environment variable substitution. The official nginx Docker image automatically processes templates in `/etc/nginx/templates/` and outputs to the directory specified by `NGINX_ENVSUBST_OUTPUT_DIR`:

#### WEB_HOST
- **Description**: Internal hostname of Rails web service
- **Required**: Yes
- **Default**: `web`
- **Used By**: nginx

#### WEB_PORT
- **Description**: Internal port of Rails web service
- **Required**: Yes
- **Default**: `80`
- **Used By**: nginx

#### CERT_PATH
- **Description**: Base path for SSL certificates
- **Required**: Yes
- **Default**: `/etc/letsencrypt/live`
- **Used By**: nginx

#### KEY_PATH
- **Description**: Base path for SSL private keys
- **Required**: Yes
- **Default**: `/etc/letsencrypt/live`
- **Used By**: nginx

#### NGINX_ENVSUBST_OUTPUT_DIR
- **Description**: Output directory for processed nginx templates
- **Required**: Yes
- **Default**: `/etc/nginx/conf.d`
- **Used By**: nginx built-in templating system
- **Note**: Automatically handled by official nginx Docker image

## Optional Variables

### Rails Performance

#### RAILS_MAX_THREADS
- **Description**: Maximum number of threads for Puma
- **Required**: No
- **Default**: `5`
- **Recommended**: `10-50` depending on server resources

#### WEB_CONCURRENCY
- **Description**: Number of Puma workers
- **Required**: No
- **Default**: `2`
- **Recommended**: `(CPU cores) - 1`

### Sidekiq Configuration

#### SIDEKIQ_CONCURRENCY
- **Description**: Number of Sidekiq worker threads
- **Required**: No
- **Default**: `10`
- **Recommended**: Adjust based on server resources and job types

### Application Features

Firebase's project ID is **not** an environment variable. It is hardcoded in
`config/initializers/firebase.rb` (and must match the value compiled into the
public JS bundle), specifically so a wrong or stale value in a deployment
`.env` can never diverge from what the app actually verifies tokens against.
Do not add a `FIREBASE_PROJECT_ID` entry back here or to any `.env` file.

#### FIREBASE_API_KEY
- **Description**: Firebase API key
- **Required**: Yes (if using Firebase Auth)
- **Security**: Can be public (client-side)

### Stripe Billing

For the full production setup sequence these variables are part of — registering webhook
endpoints, excluding them from Cloudflare's managed challenge, labelling the live prices, and
verifying each step — see `docs/guides/stripe-account-setup.md`.

#### STRIPE_SECRET_KEY
- **Description**: Stripe API secret key for server-side operations
- **Required**: Yes (if using Stripe billing)
- **Format**: Starts with `sk_live_` in production, `sk_test_` in development
- **Used By**: web, worker
- **Security**: Never commit this value; never use a live key in non-production environments

#### STRIPE_WEBHOOK_SECRET
- **Description**: Webhook signing secret(s) for Stripe event verification
- **Required**: Yes (if processing Stripe webhooks)
- **Important**: This differs between a dashboard endpoint and the `stripe listen` CLI tool. Using the wrong one is the most common signature-verification failure. Use the value from your Stripe dashboard endpoint for production and staging.
- **Used By**: web
- **Security**: Never commit this value

Accepts a **comma-separated list** of signing secrets. Stripe issues one secret
per registered endpoint, and production registers two — one per host
(`thegreatestmusic.org` and `thegreatest.games`) — so both must be present or
every delivery to the second endpoint returns 400 and Stripe eventually disables
it. Local development uses a single secret, the one `stripe listen` prints.

Rotating a secret uses the same mechanism: run with old and new configured
together until the rotation completes, then drop the old one.

#### STRIPE_LIVEMODE
- **Description**: Whether to use live Stripe keys and process real charges
- **Required**: Yes
- **Values**: `true` for production with live keys, `false` for test/sandbox keys
- **Default**: `false`
- **Used By**: web, worker
- **Guard**: The application refuses to boot if a live key (`sk_live_*`) is provided with `STRIPE_LIVEMODE=false`

### Email Configuration

#### SENDGRID_API_KEY
- **Description**: SendGrid API key, used as the SMTP password. The SMTP *username* is the literal
  string `apikey` and is not configurable.
- **Required**: Yes
- **Used By**: web, worker
- **Security**: Never commit this value. Managed via SOPS — see `deployment/SECRETS.md`.
- **Note**: A missing key does **not** fail loudly. The app boots normally — deliberately, since
  raising while `config/environments/production.rb` is still loading would crash-loop the web
  container under `bin/docker-entrypoint`'s `bash -e` and take all four sites down. Instead,
  `production.rb`'s guard skips calling `MailDeliverySettings.sendgrid_smtp` entirely when the key
  is absent, so its `MissingApiKey` raise never runs; `smtp_settings` becomes `{}` and the `mail`
  gem falls back to its own default of `localhost:25`, so every send then fails with a bare SMTP
  connection error that names neither `SENDGRID_API_KEY` nor `MissingApiKey`. The signal to look
  for instead is the boot-time warning from `config/initializers/mail_delivery_check.rb`:
  `"SENDGRID_API_KEY is not set; outbound mail will fail at send time"`.

#### MAIL_FROM_ADDRESS
- **Description**: The envelope from-address for all outbound mail. Currently
  `contact@thegreatestbooks.org`. Must be an address SendGrid recognises as a verified Sender
  Identity: if it is not, SendGrid rejects the send outright with an SMTP error, rather than
  delivering it anywhere.
- **Required**: Yes
- **Used By**: web, worker
- **Note**: One address serves every site the membership covers — books, music and games —
  deliberately. Music and games mail therefore sends from a `thegreatestbooks.org` address. SendGrid
  authenticates a *sending domain*, and only that one is set up; a per-site address would mean
  maintaining authentication and DNS for each domain, for no gain the recipient can see. The
  *display name* varies per site ("The Greatest Books", "The Greatest Music", ...) — see
  `app/lib/mail_branding.rb`.
- **Two failure modes, and they look nothing alike**: an address with no verified Sender Identity is
  **rejected** by SendGrid with a visible SMTP error. An address that *is* verified but whose domain
  authentication is incomplete or whose DNS has not propagated sends successfully and is likely
  filed as **spam** — silently, with nothing in the app reporting it. Only the second one requires
  checking the recipient's spam folder to detect.

#### ADMIN_NOTIFICATION_EMAIL
- **Description**: Recipient for administrative notifications and the `mail:smoke` test email.
- **Required**: Yes
- **Used By**: web, worker

#### MEMBERSHIP_EMAIL_SCOPE
- **Description**: Which memberships and donations this app is allowed to email about. See
  `app/lib/membership_email_scope.rb`.
- **Required**: No
- **Default**: `own_only`
- **Used By**: web, worker

  > **Before setting this to `all`, run `bin/rails billing:backfill_email_stamps` first — every
  > time, no exceptions. Doing this in the other order, or skipping the backfill, mails a welcome to
  > every legacy member on the account at the next nightly sweep.** This is the single most
  > damaging mistake available in this subsystem.
  >
  > Why: `Services::Billing::MembershipNotifier` derives email *eligibility*, not just its
  > once-only guard, from the membership's own `welcome_email_sent_at` column — any membership that
  > currently grants access (`trialing`/`active`) and has a nil stamp is owed a welcome
  > (`docs/features/email.md`'s "Durable eligibility, not transition-driven"). The instant this
  > scope opens to `all`, "owed" includes every legacy membership on the shared Stripe account,
  > because this app never welcomed any of them — their `welcome_email_sent_at` has been `nil`
  > since the account-wide migration. `bin/rails billing:backfill_email_stamps`
  > (`Services::Billing::BackfillEmailStamps`) stamps `welcome_email_sent_at`/`ended_email_sent_at`
  > on every row this scope currently blocks (`origin_domain` blank) *before* the scope opens, so
  > there is nothing left owed once it does. It is additive and idempotent — safe to run more than
  > once, and it never sends anything itself — but it must run **before**, never after, this
  > variable is set to `all`.

- **Values**:
  - `own_only` — email only about memberships and donations **this app sold**. Correct while the
    legacy books app is live, because legacy still emails its own subscribers, and both apps'
    webhook endpoints receive every event on the one shared Stripe account — without this scope, a
    legacy subscriber would get the same welcome or cancellation email twice, once from each app.
  - `all` — email about everything on the account, legacy-sold memberships and donations included.
    **Set this at legacy cutover, and only after `bin/rails billing:backfill_email_stamps` has
    already been run** (see above) — otherwise every legacy-era membership — including the entire
    account-wide migration, which predates checkout and carries no `origin_domain` — will silently
    never receive a cancellation email from anyone again, since legacy will have stopped running.
  - Any unrecognised value (a typo, an empty string that isn't literally unset) is treated as
    `own_only`, deliberately: the failure direction matters more than convenience. A misconfigured
    value must never silently start double-emailing paying customers; it should just look like the
    switch was never flipped.

## Example .env File

```bash
# Rails
RAILS_ENV=production
RAILS_MASTER_KEY=your_master_key_here
SECRET_KEY_BASE=your_secret_key_base_here

# Database
POSTGRES_HOST=postgresql.example.com
POSTGRES_PORT=5432
POSTGRES_DATABASE=the_greatest_production
POSTGRES_USER=the_greatest
POSTGRES_PASSWORD=your_postgres_password_here

# Redis
REDIS_URL=redis://redis:6379/1

# OpenSearch
OPENSEARCH_URL=https://opensearch.example.com:9200

# SSL Certificates
CLOUDFLARE_API_TOKEN=your_cloudflare_token_here

# Nginx (docker-compose sets these by default)
NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/conf.d
WEB_HOST=web
WEB_PORT=80
CERT_PATH=/etc/letsencrypt/live
KEY_PATH=/etc/letsencrypt/live

# Firebase (if using Firebase Auth)
# FIREBASE_PROJECT_ID is not read by the app — it's hardcoded in
# config/initializers/firebase.rb. Do not set it here.
FIREBASE_API_KEY=your_firebase_api_key_here

# Stripe Billing
STRIPE_SECRET_KEY=sk_live_your_stripe_secret_key_here
STRIPE_WEBHOOK_SECRET=whsec_music_endpoint_secret,whsec_games_endpoint_secret  # one per registered endpoint
STRIPE_LIVEMODE=true

# Email Configuration
SENDGRID_API_KEY=SG.your_sendgrid_api_key_here
MAIL_FROM_ADDRESS=contact@thegreatestbooks.org
ADMIN_NOTIFICATION_EMAIL=you@example.com
# MEMBERSHIP_EMAIL_SCOPE=own_only  # optional; run `bin/rails billing:backfill_email_stamps` BEFORE setting to "all" at legacy cutover — see above

# Performance Tuning (optional)
RAILS_MAX_THREADS=50
WEB_CONCURRENCY=2
SIDEKIQ_CONCURRENCY=10
```

## Generating Secrets

### RAILS_MASTER_KEY
Generated automatically when running:
```bash
rails credentials:edit
```
The key is stored in `config/master.key` (never commit this file).

### SECRET_KEY_BASE
Generate a new secret:
```bash
rails secret
```

### CLOUDFLARE_API_TOKEN
1. Log in to Cloudflare Dashboard
2. Go to My Profile > API Tokens
3. Create Token
4. Use "Edit zone DNS" template
5. Select specific zones or all zones
6. Copy token (shown only once)

## Security Best Practices

1. **Never commit secrets**: Use `.gitignore` to exclude `.env` files
2. **Use strong passwords**: Generate with `openssl rand -hex 64`
3. **Rotate regularly**: Change database passwords and API tokens periodically
4. **Limit permissions**: Use least-privilege principle for database users and API tokens
5. **Encrypt at rest**: Use encrypted storage for backup credentials
6. **Audit access**: Review who has access to production secrets

## Loading Environment Variables

### Docker Compose
Variables are automatically loaded from `.env` file in the same directory as `docker-compose.prod.yml`.

### Manual Loading
```bash
export $(grep -v '^#' .env | xargs)
```

### Verify Variables
```bash
docker compose -f docker-compose.prod.yml exec web env | grep POSTGRES
docker compose -f docker-compose.prod.yml exec web env | grep RAILS
```

## Troubleshooting

### Missing Variables
If a container fails to start due to missing variables:
```bash
docker compose -f docker-compose.prod.yml logs web
```

Look for errors like:
```
ERROR: Missing required environment variable: POSTGRES_PASSWORD
```

### Variable Not Updating
After changing `.env`:
```bash
docker compose -f docker-compose.prod.yml down
docker compose -f docker-compose.prod.yml up -d
```

### Database Connection Fails
Verify database variables:
```bash
docker compose -f docker-compose.prod.yml exec web bin/rails runner "puts ActiveRecord::Base.connection.execute('SELECT version()').first"
```
