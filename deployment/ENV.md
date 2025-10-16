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

#### FIREBASE_PROJECT_ID
- **Description**: Firebase project ID for authentication
- **Required**: Yes (if using Firebase Auth)
- **Example**: `thegreatestmusic-org`

#### FIREBASE_API_KEY
- **Description**: Firebase API key
- **Required**: Yes (if using Firebase Auth)
- **Security**: Can be public (client-side)

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
FIREBASE_PROJECT_ID=thegreatestmusic-org
FIREBASE_API_KEY=your_firebase_api_key_here

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
