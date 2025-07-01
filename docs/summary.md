# The Greatest - Project Summary

## Overview
The Greatest is a unified platform for discovering and tracking the greatest content across multiple media types. It extends the successful model of [The Greatest Books](https://thegreatestbooks.org) to encompass music, movies, and video games.

### Project Evolution
- **Current State**: The Greatest Books aggregates book lists to create a master ranking of the greatest books of all time
- **Next Phase**: Expand to a multi-domain platform covering books, music, movies, and video games under "The Greatest" brand
- **Architecture**: Single codebase serving multiple sites based on hostname (e.g., books.thegreatest.app, movies.thegreatest.app)

## Primary Purpose
Create the definitive discovery and tracking platform for high-quality content across multiple media types, helping users find their next favorite book, album, movie, or game through aggregated rankings and personalized recommendations.

## Core Features

### 1. List Aggregation and Ranking
- **Data Sources**: Aggregate "best of" lists from critics, publications, and authoritative sources
- **Ranking Algorithm**: Weighted scoring system based on list authority and item frequency
- **Dynamic Updates**: Continuously incorporate new lists and adjust rankings
- **Transparency**: Show which lists contribute to each item's ranking

### 2. User Lists and Tracking
Universal list types adapted for each media:
- **Books**: My favorites, Want to read, Currently reading, Have read
- **Music**: My favorites, Want to listen, Currently listening, Have listened
- **Movies**: My favorites, Want to watch, Currently watching, Have watched
- **Games**: My favorites, Want to play, Currently playing, Have played

### 3. Discovery - Recommendations Engine
- **Collaborative Filtering**: Find similar users and recommend their favorites
- **Content-Based**: Analyze metadata (genres, themes, creators) for similarities
- **Hybrid Approach**: Combine multiple signals for better recommendations
- **Cross-Media**: Potential for cross-pollination (e.g., "If you like this book, try this movie")

### 4. Discovery - Advanced Search and Filtering
Universal filters:
- **Categories**: Genres, sub-genres, themes, tags
- **Time Periods**: Release/publication date ranges
- **Geography**: Country of origin, settings/locations
- **Creators**: Authors, directors, artists, developers
- **Awards**: Major award winners and nominees

Media-specific filters:
- **Books**: Page count, original language, series vs standalone
- **Music**: Album length, record label, instrumental vs vocal
- **Movies**: Runtime, rating (PG, R, etc.), format (feature, documentary)
- **Games**: Platform, playtime, single vs multiplayer

### 5. Reviews and Ratings
- **User Ratings**: 1-5 star system with optional half-stars
- **Written Reviews**: Structured reviews with pros/cons
- **Verified Ownership**: Option to verify user has read/watched/played/listened
- **Review Voting**: Helpful/unhelpful voting system
- **Critic Reviews**: Aggregate professional reviews with links to sources

### 6. User Interface
- **Design Philosophy**: Clean, fast, and intuitive - prioritizing content discovery
- **Responsive Design**: Seamless experience across desktop, tablet, and mobile
- **Performance First**: Sub-second page loads using modern web techniques
- **Accessibility**: WCAG 2.1 AA compliant
- **Personalization**: Customizable themes and display preferences

## Technical Architecture

### Backend
- **Framework**: Ruby on Rails 8
- **Database**: PostgreSQL 17
- **Caching**: Redis
- **Background Jobs**: Sidekiq (for list aggregation, recommendations, data processing)
- **AI Integration**: API clients for ChatGPT, Google AI, Claude, etc.
  - Used for: Content enrichment, recommendation improvements, review summarization
- **Search**: OpenSearch (for advanced filtering and full-text search)
- **Deployment**: Docker containers
- **Authentication**: Firebase Authentication

### Frontend
- **Build Tool**: Rollup for JavaScript bundling
  - Separate build configurations per domain
  - Multiple entry points (books.js, movies.js, games.js, music.js)
  - Shared modules with domain-specific bundles
  - Tree-shaking for optimal bundle sizes
- **CSS Framework**: Tailwind CSS 4 with DaisyUI 5 components
- **CSS Processing**: PostCSS with Tailwind
- **Interactivity**: Stimulus JS for progressive enhancement
- **Navigation**: Turbo Frames for SPA-like experience
- **Components**: ViewComponents for reusable UI elements
- **Asset Serving**: Direct from public/ folder via Nginx (no Rails asset pipeline)

### Infrastructure
- **Web Server**: Nginx (reverse proxy to Rails)
- **CDN**: Cloudflare for global content delivery
- **Storage**: Cloudflare R2 for cover images and media assets
- **Admin**: Avo HQ for internal content management
- **Monitoring**: Performance and error tracking
- **Container Orchestration**: Docker-based deployment strategy

### Multi-Site Architecture
- **Domain Strategy**: Each media type has its own domain
  - Books: thegreatestbooks.org (existing)
  - Music: thegreatestmusic.org
  - Games: thegreatest.games
  - Movies: thegreatestmovies.org
- **Request Routing**: Detect hostname and serve appropriate site experience
- **Build Pipeline**: 
  - Separate application.html.erb for each domain
  - Domain-specific JavaScript bundles via Rollup
  - Separate CSS builds per domain
  - Shared components with site-specific overrides
  - Static assets served directly by Nginx
- **Shared Core**: 
  - Common models and database
  - Shared business logic and services
  - Base controllers with site-specific inheritance
  - Reusable ViewComponents with customizable styling
- **Site-Specific Elements**:
  - Custom layouts and views
  - Unique branding and color schemes
  - Specialized features per media type
  - Different meta tags and SEO configuration
- **Configuration**: 
  - Host-based configuration loading
  - Environment variables per domain
  - Feature flags for site-specific functionality

## Data Model Highlights
- **Polymorphic Items**: Base Item model with type-specific STI or associations
- **Flexible Metadata**: JSONB fields for media-specific attributes
- **List Items**: Junction table for list aggregation with source tracking
- **User Interactions**: Unified tracking across all media types

## Implementation Challenges

### Multi-Domain Architecture
The most complex aspect of this project is serving multiple distinct sites from a single Rails codebase:

1. **Build Management**
   - Rollup configuration for separate builds per domain
   - CSS scoping to prevent style bleeding between sites
   - Efficient build process and deployment
   - CDN configuration for multiple domains

2. **Request Handling**
   - Middleware to detect current domain early in request cycle
   - Dynamic layout selection based on hostname
   - Proper handling of shared vs site-specific routes

3. **Development Environment**
   - Local development with multiple hostnames (using /etc/hosts or similar)
   - Testing across different domain contexts
   - Deployment scripts aware of multi-domain setup

4. **Performance Considerations**
   - Avoid loading unnecessary assets for other domains
   - Efficient caching strategies per domain
   - Shared component optimization

5. **Maintenance Complexity**
   - Keeping sites visually distinct while sharing code
   - Managing domain-specific configurations
   - Preventing regressions across sites when updating shared code
- **API Access**: Public API for developers and researchers
- **Mobile Apps**: Native iOS/Android apps for enhanced mobile experience
- **Social Features**: Following users, sharing lists, discussion forums
- **Gamification**: Achievements, badges, reading/watching challenges
- **Premium Features**: Ad-free experience, advanced analytics, early access

## Success Metrics
- **User Engagement**: Daily active users, items tracked per user
- **Content Coverage**: Percentage of notable works included
- **Recommendation Quality**: Click-through and satisfaction rates
- **Performance**: Page load times, API response times
- **Community**: User-generated reviews and lists