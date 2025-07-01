# The Greatest

## Project Overview [README.OVERVIEW]
A web application that aggregates books, music, movie, and video game lists displays a single list of 
The greatest of all time. Everything is searchable and filterable and users can create their own lists.

## Setup Instructions [README.SETUP]
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

## Tech Stack [README.TECH]
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

## Directory Structure [README.DIR]
```
web-app/app/     - Core application code
├─ controllers/  - Request handlers
├─ models/       - Data models
├─ views/        - UI templates
├─ components/   - ViewComponents
├─ javascript/   - Frontend scripts
└─ assets/       - Static resources

docs/            - Project documentation
├─ DEVELOPER_CORE_VALUES.md
├─ BUSINESS_RULES.md
└─ ...
```

## Quick Start Guide [README.QS]
```
1. Clone repository
2. Follow setup instructions
3. Visit http://localhost:3000
4. Read docs/DEVELOPER_GETTING_STARTED.md
```

→ Next: See BUSINESS_RULES.md