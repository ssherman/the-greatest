# The Greatest

**Version 3** - The next evolution of [The Greatest Books](https://thegreatestbooks.org), expanding beyond books to power movies, music, games, and eventually books across multiple domains from a single codebase.

A multi-domain Rails application serving different media experiences from a single codebase. Each domain provides a unique, themed experience for music, movies, and games while sharing the same backend infrastructure.

## 🎵 🎬 🎮 Domains

- **Music**: [dev.thegreatestmusic.org](https://dev.thegreatestmusic.org) - Blues and purples theme with music notes branding
- **Movies**: [dev.thegreatestmovies.org](https://dev.thegreatestmovies.org) - Reds and oranges theme with film reels branding  
- **Games**: [dev.thegreatest.games](https://dev.thegreatest.games) - Greens and cyans theme with game controllers branding

## ✨ Features

- **Multi-Domain Architecture**: Single Rails backend serving different experiences per domain
- **Domain-Specific Styling**: Each domain has unique CSS themes and branding
- **Shared Infrastructure**: Common database, authentication, and business logic
- **Modern UI**: Built with DaisyUI and Tailwind CSS for beautiful, responsive interfaces
- **Development Ready**: Complete local development setup with Docker and Caddy

## 🏗️ Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Music Domain  │    │  Movies Domain  │    │   Games Domain  │
│  (dev.thegreat- │    │ (dev.thegreat-  │    │ (dev.thegreat-  │
│   estmusic.org) │    │  estmovies.org) │    │    est.games)   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌─────────────────┐
                    │   Rails App     │
                    │   (web-app/)    │
                    │                 │
                    │ ┌─────────────┐ │
                    │ │Controllers  │ │
                    │ │Views        │ │
                    │ │Models       │ │
                    │ │Assets       │ │
                    │ └─────────────┘ │
                    └─────────────────┘
                                 │
                    ┌─────────────────┐
                    │   PostgreSQL    │
                    │   (Docker)      │
                    └─────────────────┘
```

## 🚀 Quick Start

### Prerequisites

- **Docker Desktop** - For database and services
- **Go** - For building Caddy with Cloudflare plugin
- **Ruby** - Rails application (managed via rbenv/rvm)
- **Node.js** - For asset compilation

### Installation

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd the-greatest
   ```

2. **Follow the complete setup guide**
   
   📖 **[Development Setup Guide](docs/dev_setup.md)** - Complete installation and configuration instructions

3. **Start the application**
   ```bash
   # Start Docker services
   docker-compose up -d
   
   # Start Rails (in web-app directory)
   cd web-app
   bin/dev
   
   # Start Caddy (in root directory, new terminal)
   sudo caddy run --config Caddyfile
   ```

4. **Visit the domains**
   - Music: https://dev.thegreatestmusic.org
   - Movies: https://dev.thegreatestmovies.org
   - Games: https://dev.thegreatest.games

## 📁 Project Structure

```
the-greatest/
├── docs/                          # Documentation
│   ├── dev_setup.md              # Development setup guide
│   └── todos/                    # Project tasks and features
├── web-app/                      # Rails application
│   ├── app/
│   │   ├── controllers/
│   │   │   ├── music/            # Music domain controllers
│   │   │   ├── movies/           # Movies domain controllers
│   │   │   └── games/            # Games domain controllers
│   │   ├── views/
│   │   │   ├── layouts/
│   │   │   │   ├── music/        # Music domain layouts
│   │   │   │   ├── movies/       # Movies domain layouts
│   │   │   │   └── games/        # Games domain layouts
│   │   │   └── [domain]/         # Domain-specific views
│   │   └── assets/stylesheets/
│   │       ├── music/            # Music domain CSS
│   │       ├── movies/           # Movies domain CSS
│   │       └── games/            # Games domain CSS
│   ├── config/
│   │   └── routes.rb             # Domain-constrained routes
│   └── lib/constraints/
│       └── domain_constraint.rb  # Domain routing logic
├── Caddyfile                     # Caddy reverse proxy config
├── docker-compose.yml            # Docker services
└── README.md                     # This file
```

## 🛠️ Development

### Key Technologies

- **Rails 8** - Web framework
- **PostgreSQL** - Database
- **Tailwind CSS** - Styling framework
- **DaisyUI** - Component library
- **Caddy** - Reverse proxy with automatic HTTPS
- **Docker** - Containerization

### Development Workflow

1. **Make changes** in the `web-app/` directory
2. **CSS changes** are automatically compiled by `bin/dev`
3. **Database changes** use standard Rails migrations
4. **Test changes** with `bin/rails test` in the web-app directory

### Domain-Specific Development

Each domain has its own:
- **Controller namespace** (`music/`, `movies/`, `games/`)
- **Layout files** with unique themes
- **CSS files** with domain-specific styling
- **Views** for domain-specific content

## 📚 Documentation

- **[Development Setup](docs/dev_setup.md)** - Complete local development guide
- **[Project Tasks](docs/todos/)** - Feature development and project management

## 🧪 Testing

```bash
cd web-app
bin/rails test
```

## 🚀 Deployment

This application is designed for multi-domain deployment with:
- **Domain-specific assets** for optimal performance
- **Shared backend** for efficient resource usage
- **Caddy reverse proxy** for automatic HTTPS and routing
- **Docker containerization** for consistent environments

## 🤝 Contributing

1. Follow the [development setup guide](docs/dev_setup.md)
2. Make changes in feature branches
3. Ensure tests pass: `cd web-app && bin/rails test`
4. Test all domains work correctly
5. Submit pull requests

## 📄 License

[Add your license information here]

## 🆘 Support

- **Setup Issues**: Check the [development setup guide](docs/dev_setup.md)
- **Bug Reports**: Create an issue with detailed reproduction steps

---

**The Greatest** - One codebase, multiple domains, infinite possibilities. 🎵🎬🎮 