# Development Setup Guide

## Overview
This guide will help you set up "The Greatest" multi-domain Rails application for local development. The application serves different experiences for music, movies, and games domains from a single codebase.

## Prerequisites

### Required Software
- **Docker & Docker Compose** - For database and services
- **Go** - For building Caddy with custom plugins
- **Ruby** - Rails application (managed via rbenv/rvm)
- **Node.js** - For asset compilation

### System Requirements
- Ubuntu/Debian Linux or macOS
- At least 4GB RAM
- 10GB free disk space

## Installation Steps

### 1. Install Docker Desktop

Docker Desktop includes both Docker and Docker Compose, making setup simple:

#### macOS
```bash
# Install Docker Desktop
brew install --cask docker
```



#### Ubuntu/Debian
```bash
# Install Docker Desktop
sudo apt-get update
sudo apt-get install ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 2. Install Go

#### Ubuntu/Debian
```bash
# Install Go
wget https://go.dev/dl/go1.21.0.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.0.linux-amd64.tar.gz

# Add to PATH
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
source ~/.bashrc
```

#### macOS
```bash
brew install go
```



### 3. Install Caddy with Cloudflare Plugin

Since the standard Caddy download doesn't include the Cloudflare plugin, we need to build it with `xcaddy`:

```bash
# Install xcaddy
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

# Build Caddy with Cloudflare plugin
xcaddy build --with github.com/caddy-dns/cloudflare

# Move to a location in your PATH
sudo mv caddy /usr/local/bin/
sudo chmod +x /usr/local/bin/caddy
```

**Alternative**: Download from [Caddy's download page](https://caddyserver.com/download) and manually add the Cloudflare plugin.

### 4. Configure Environment

#### Create .env file
Create a `.env` file in the project root:

```bash
# .env
CLOUDFLARE_API_TOKEN=your_cloudflare_api_token_here
```

**Note**: You'll need to obtain a Cloudflare API token from your Cloudflare dashboard with DNS edit permissions.

#### Update Hosts File

Add the development domains to your local hosts file:

**Linux/macOS** (`/etc/hosts`):
```bash
sudo nano /etc/hosts
```



Add these lines:
```
127.0.0.1 dev.thegreatestmusic.org
127.0.0.1 dev.thegreatestmovies.org
127.0.0.1 dev.thegreatest.games
```

### 5. Configure Caddy for Port 443

#### Linux
```bash
# Allow Caddy to bind to port 443
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/caddy
```

#### macOS
```bash
# macOS requires running with sudo for port 443
# This will be handled in the startup script
```



## Starting the Application

### 1. Start Docker Services
From the project root:
```bash
docker-compose up -d
```

This will start:
- PostgreSQL database
- Redis (if configured)
- Any other services defined in `docker-compose.yml`

### 2. Start Rails Application
Navigate to the web-app directory and start the Rails server:
```bash
cd web-app
bin/dev
```

This will:
- Start the Rails server on port 3000
- Watch and compile CSS assets for all domains
- Start any other development processes

### 3. Start Caddy Reverse Proxy
From the project root, start Caddy:
```bash
# Linux/macOS
sudo caddy run --config Caddyfile


```

## Verifying the Setup

### Check Services
```bash
# Check Docker services
docker-compose ps

# Check Rails server
curl http://localhost:3000

# Check Caddy
curl -k https://dev.thegreatestmusic.org
```

### Test All Domains
Visit these URLs in your browser:
- **Music**: https://dev.thegreatestmusic.org
- **Movies**: https://dev.thegreatestmovies.org  
- **Games**: https://dev.thegreatest.games

Each should show a different themed welcome page with domain-specific styling.

## Development Workflow

### Making Changes
1. **Rails Code**: Edit files in `web-app/`
2. **CSS Changes**: Edit files in `web-app/app/assets/stylesheets/`
3. **Layout Changes**: Edit files in `web-app/app/views/layouts/`
4. **Routes**: Edit `web-app/config/routes.rb`

### Asset Compilation
CSS is automatically compiled when you run `bin/dev` in the web-app directory. The process watches for changes and rebuilds:
- `music.css` for the music domain
- `movies.css` for the movies domain
- `games.css` for the games domain

### Database Changes
```bash
cd web-app
rails db:migrate
rails db:seed  # if you have seed data
```

## Troubleshooting

### Common Issues

#### Port 443 Already in Use
```bash
# Check what's using port 443
sudo lsof -i :443

# Stop conflicting service
sudo systemctl stop apache2  # or nginx, etc.
```

#### Caddy Permission Denied
```bash
# Linux: Set capabilities
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/caddy

# macOS/Windows: Run with sudo/Administrator
```

#### Docker Services Not Starting
```bash
# Check Docker status
docker system info

# Restart Docker
sudo systemctl restart docker

# Check docker-compose logs
docker-compose logs
```

#### Rails Assets Not Loading
```bash
# Check asset paths
cd web-app
ls -la app/assets/builds/

# Restart bin/dev to rebuild assets
```

#### Domain Not Resolving
```bash
# Check hosts file
cat /etc/hosts | grep thegreatest

# Test DNS resolution
nslookup dev.thegreatestmusic.org

# Flush DNS cache (macOS)
sudo dscacheutil -flushcache
```

### Logs and Debugging

#### Rails Logs
```bash
cd web-app
tail -f log/development.log
```

#### Caddy Logs
```bash
# Check Caddy logs
sudo journalctl -u caddy -f

# Or if running manually, check terminal output
```

#### Docker Logs
```bash
docker-compose logs -f
```

## Configuration Files

### Caddyfile
The main Caddy configuration file should be in the project root:

```caddy
# Caddyfile
dev.thegreatestmusic.org {
    reverse_proxy localhost:3000
    tls internal
}

dev.thegreatestmovies.org {
    reverse_proxy localhost:3000
    tls internal
}

dev.thegreatest.games {
    reverse_proxy localhost:3000
    tls internal
}
```

### Docker Compose
Example `docker-compose.yml` in the project root:

```yaml
version: '3.8'
services:
  db:
    image: postgres:15
    environment:
      POSTGRES_DB: the_greatest_development
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: password
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
```

## Security Notes

### Development vs Production
- This setup is for **development only**
- Uses self-signed certificates
- No production security measures
- Database passwords are simple

### API Tokens
- Keep your Cloudflare API token secure
- Never commit `.env` files to version control
- Use different tokens for different environments

## Next Steps

Once the basic setup is working:

1. **Explore the Codebase**: Check out the domain-specific controllers and layouts
2. **Run Tests**: `cd web-app && bin/rails test`
3. **Add Features**: Start building domain-specific functionality
4. **Customize Styling**: Modify the DaisyUI themes for each domain

## Support

If you encounter issues:

1. Check the troubleshooting section above
2. Review the logs for error messages
3. Ensure all prerequisites are properly installed
4. Verify network connectivity and DNS resolution

For additional help, refer to:
- [Caddy Documentation](https://caddyserver.com/docs/)
- [Rails Guides](https://guides.rubyonrails.org/)
- [Docker Documentation](https://docs.docker.com/) 