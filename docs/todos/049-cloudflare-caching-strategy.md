# 049 - Cloudflare Caching Strategy for Ranking Pages

## Status
- **Status**: Not Started
- **Priority**: Medium
- **Created**: 2025-10-11
- **Started**:
- **Completed**:
- **Developer**: TBD

## Overview
Implement application-level cache control headers for ranking pages (/albums, /songs, /artists, /movies, /games) to enable efficient Cloudflare edge caching. This will improve page load times globally and reduce server load.

## Context
The Greatest serves ranking pages that are largely static (updated periodically when new data is imported). These pages are ideal candidates for CDN caching. Previously, caching was managed in nginx configuration, which required manual updates when new cacheable pages were added.

Moving cache control to the Rails application level provides:
- Co-location of cache logic with application code
- Automatic cache headers for new pages
- Dynamic control based on user state
- No deployment friction when adding new endpoints

## Requirements

### Controller-Level Cache Headers
- [ ] Create `CacheableRankings` concern for reusability across controllers
- [ ] Apply cache headers to ranking index pages (albums, songs, artists, movies, games)
- [ ] Apply cache headers to ranking show pages (individual items)
- [ ] Different cache durations for different page types
- [ ] Conditional caching based on user authentication state

### Nginx Configuration
- [ ] Ensure nginx passes through Cache-Control headers from Rails
- [ ] Ensure nginx passes through Expires headers from Rails
- [ ] No page-specific caching rules in nginx (handled by Rails)

### Cache Invalidation
- [ ] Cloudflare API integration for cache purging
- [ ] Purge cache after data imports/updates
- [ ] Purge specific URLs vs full cache clear

### Testing
- [ ] Verify cache headers in development
- [ ] Test cache headers in production (curl -I)
- [ ] Verify Cloudflare respects cache headers
- [ ] Test cache invalidation works

## Technical Approach

### CacheableRankings Concern

```ruby
# app/controllers/concerns/cacheable_rankings.rb
module CacheableRankings
  extend ActiveSupport::Concern

  included do
    before_action :set_ranking_cache_headers, only: [:index, :show]
  end

  private

  def set_ranking_cache_headers
    if user_signed_in?
      # Shorter cache for logged-in users
      expires_in 5.minutes, public: false, must_revalidate: true
    else
      # Longer cache for anonymous users
      expires_in 1.hour, public: true, must_revalidate: true
    end
  end
end
```

### Controller Implementation

```ruby
class Music::AlbumsController < ApplicationController
  include CacheableRankings

  def index
    @albums = Music::Album.ranked.limit(100)
  end

  def show
    @album = Music::Album.friendly.find(params[:id])
  end
end

class Music::SongsController < ApplicationController
  include CacheableRankings

  def index
    @songs = Music::Song.ranked.limit(100)
  end
end
```

### Nginx Configuration

```nginx
location / {
    proxy_pass http://web:3000;

    # Pass through cache headers from Rails
    proxy_pass_header Cache-Control;
    proxy_pass_header Expires;

    # Standard reverse proxy headers
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

### Cache Invalidation Service

```ruby
# app/services/cloudflare_cache_service.rb
class CloudflareCacheService < ApplicationService
  def self.purge_urls(urls)
    new(urls: urls).call
  end

  def initialize(urls:)
    @urls = urls
  end

  def call
    # Cloudflare API call to purge specific URLs
    response = connection.post do |req|
      req.url '/client/v4/zones/{zone_id}/purge_cache'
      req.headers['Authorization'] = "Bearer #{ENV['CLOUDFLARE_API_TOKEN']}"
      req.headers['Content-Type'] = 'application/json'
      req.body = { files: @urls }.to_json
    end

    Result.new(
      success?: response.success?,
      data: response.body,
      errors: response.success? ? [] : [response.body]
    )
  end

  private

  def connection
    @connection ||= Faraday.new(url: 'https://api.cloudflare.com')
  end
end
```

### Cache Purging After Import

```ruby
# In data importer or background job
class Music::ImportAlbumsJob
  include Sidekiq::Job

  def perform(*)
    # Import logic...

    # Purge cache after successful import
    CloudflareCacheService.purge_urls([
      "https://thegreatestmusic.org/albums",
      "https://thegreatestmusic.org/songs"
    ])
  end
end
```

## Dependencies
- 048-production-deployment-infrastructure.md (nginx configuration)
- Cloudflare API token with cache purge permissions
- Faraday gem (likely already installed)

## Acceptance Criteria
- [ ] Ranking pages return Cache-Control headers
- [ ] Cloudflare caches pages based on headers
- [ ] Cache duration differs for logged-in vs anonymous users
- [ ] Cache invalidation works via Cloudflare API
- [ ] No manual nginx configuration needed for new pages
- [ ] Page load times improved for cached pages
- [ ] Server load reduced due to edge caching

## Design Decisions

### Why Application-Level Instead of Nginx?
- Cache logic lives with application code
- No deployment friction when adding new pages
- Can vary cache based on user state, query params, etc.
- Easier for AI agents to understand and maintain
- Follows Rails conventions

### Why Different Cache Times for Authenticated Users?
- Logged-in users may see personalized content in the future
- Shorter cache reduces risk of stale personalized data
- Anonymous users benefit from longer cache (majority of traffic)

### Why Cloudflare Purging Instead of Cache Expiration?
- Data updates are event-driven (imports, manual changes)
- Explicit purging gives precise control
- Avoids waiting for TTL expiration
- Can purge specific pages vs full site

### Cache Duration Strategy
- **Index pages**: 1 hour (frequently accessed, rarely change)
- **Show pages**: 6 hours (less frequently updated)
- **Logged-in users**: 5 minutes (potential for personalization)
- **After import**: Immediate purge (fresh data)

## Related Tasks
- 048-production-deployment-infrastructure.md (nginx config setup)
- Future: Vary cache by query params (sort, filter)
- Future: Cache warming after imports
- Future: Cache analytics and monitoring

## Security Considerations
- Never cache authenticated content as public
- Cloudflare API token with minimal permissions (cache purge only)
- Don't leak user-specific data in cached responses
- Verify Vary headers if needed for conditional responses

## Performance Considerations
- 1-hour cache can serve millions of requests without hitting origin
- Cloudflare edge caching reduces latency globally
- Server resource usage reduced significantly
- Monitor cache hit rates in Cloudflare analytics

---

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Approach Taken
*To be documented during implementation*

### Key Files Changed
*To be documented during implementation*

### Challenges Encountered
*To be documented during implementation*

### Deviations from Plan
*To be documented during implementation*

### Testing Approach
1. Add concern to test controller
2. Make request with curl -I to verify headers
3. Deploy to production
4. Verify Cloudflare respects cache headers (check CF-Cache-Status header)
5. Test cache purging works
6. Monitor cache hit rates

### Future Improvements
- Cache warming after imports (pre-populate Cloudflare cache)
- Vary cache by query parameters (sort, filter options)
- Edge-side includes (ESI) for dynamic portions of pages
- Real-time cache analytics dashboard
- Stale-while-revalidate strategy for zero downtime updates

### Lessons Learned
*To be documented during implementation*

### Related PRs
*To be documented when PRs are created*

### Documentation Updated
- [ ] Update deployment/ENV.md with CLOUDFLARE_API_TOKEN
- [ ] Document cache strategy in relevant controller docs
- [ ] Update feature documentation with caching details
