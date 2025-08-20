# The Greatest

## Project Overview
A web application that aggregates books, music, movie, and video game lists displays a single list of 
The greatest of all time. Everything is searchable and filterable and users can create their own lists.

## Setup Instructions
```
cd rails
Ruby Version: 3.4.2
Node Version: 22.14.0

# Installation
cd web-app
bundle install
yarn install

# Database Setup
cd web-app
bin/rails db:setup

# Start Development Server
cd web-app
bin/dev
```

## Tech Stack
```
Backend
├─ Ruby on Rails 8
├─ PostgreSQL 17
├─ Ruby OPENAI gem
├─ Open Search
└─ Firebase Authentication

Frontend
├─ Tailwind CSS 4
├─ Daisy UI 5
├─ ViewComponent
├─ Stimulus/Turbo-frames
└─ Rollup
```

## Directory Structure
```
web-app/app/     - Core application code
├─ controllers/  - Request handlers
├─ models/       - Data models
├─ views/        - UI templates
├─ components/   - ViewComponents
├─ javascript/   - Frontend scripts
└─ assets/       - Static resources

docs/            - Project documentation
├─ dev-core-values.md
├─ testing.md
└─ ...
```

## Quick Start Guide
```
1. Clone repository
2. Follow setup instructions
3. Visit http://localhost:3000
4. Explore the application
```

## Documentation
- **[Project Summary](summary.md)** - High-level project overview, evolution, and architecture
- **[Development Setup](dev_setup.md)** - Detailed setup guide with Docker, Caddy, and multi-domain configuration
- **[Developer Core Values](dev-core-values.md)** - AI-first development principles and coding standards
- **[Testing Guide](testing.md)** - Testing philosophy, Minitest setup, and best practices
- **[Documentation Guide](documentation.md)** - How to document classes and maintain project documentation
- **[Task Management Guide](todo-guide.md)** - How tasks are tracked and organized using markdown files
- **[Current Todo List](todo.md)** - Active tasks and project priorities