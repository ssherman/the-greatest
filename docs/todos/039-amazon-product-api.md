# 039 - Amazon Product API Integration for Music Albums

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-09-17
- **Started**: 2025-09-20
- **Completed**: 2025-09-20
- **Developer**: Claude Code

## Overview
Add Amazon Product API integration as an asynchronous DataImporter provider for Music::Album. This will be our first async provider that launches a background job and returns success immediately, enabling the import of album product data, images, and external purchase links from Amazon.

## Context
- Why is this needed? Users need direct purchase links and product images for music albums
- What problem does it solve? Currently albums only have MusicBrainz data; Amazon provides commercial product data, pricing, and high-quality images
- How does it fit into the larger system? Extends existing DataImporter framework with async capabilities and integrates with existing Image and ExternalLink systems

## Requirements
- [x] Create Amazon DataImporter provider for Music::Album that launches background job
- [x] Implement AmazonProductEnrichmentJob with serial queue (concurrency: 1) for API rate limiting
- [x] Create service object for Amazon API calls, AI validation, and data processing
- [x] Integrate AI matching to confirm Amazon products match our albums
- [x] Create ExternalLink records for Amazon products with full metadata
- [x] Download and set primary_image from highest-ranked Amazon product with image
- [x] Support single Amazon Music search using artist and title parameters
- [x] Handle API rate limits and error scenarios gracefully

## Technical Approach

### Async Provider Pattern
Implement first asynchronous provider following pattern:
1. Provider immediately returns success and launches background job
2. Job performs actual API calls, AI validation, and data enrichment
3. Item saved immediately by DataImporter, then enhanced by background job

### Amazon API Integration
- Use existing `vacuum` gem for Amazon Product API calls
- Single search using `search_index: 'Music'` (covers all music products)
- Use vacuum's artist/title parameters: `artist: 'Depeche Mode', title: 'Black Celebration'`
- Request resources: ItemInfo, Images, Offers, BrowseNodeInfo for sales ranking

### AI Validation
- Adapt existing AmazonMatchConfirmation AI chat pattern for music albums
- Use existing AiChat model infrastructure instead of custom Openai::Chat classes
- Validate that Amazon results match our album (artist + title matching)

### Data Processing
- Create ExternalLink for each validated Amazon product
- Store full Amazon API response in ExternalLink metadata field
- Download primary image from highest sales-ranked product with image
- Use existing `down` gem and Image model infrastructure

### Queue Configuration
- Implement Sidekiq serial queue with concurrency: 1 for API rate limiting
- Follow existing pattern from Music::ImportAlbumReleasesJob

## Dependencies
- vacuum gem (already installed)
- down gem (already installed)
- Existing DataImporter framework
- Existing AiChat, ExternalLink, and Image models
- Amazon Product API credentials via environment variables

## Acceptance Criteria
- [x] User can trigger Amazon enrichment via DataImporter for any album
- [x] System performs single Amazon Music search using artist/title parameters
- [x] AI validates Amazon products match the album before creating links
- [x] External links created with Amazon source and full metadata
- [x] Primary image downloaded and attached if Amazon product has image
- [x] Background job respects API rate limits (serial queue)
- [x] All operations handle errors gracefully without breaking imports
- [x] Performance: Async provider returns immediately, enrichment happens in background

## Design Decisions
- **Async Provider**: First async provider implementation - returns success immediately
- **AI Integration**: Use existing AiChat model instead of custom chat classes
- **Queue Strategy**: Serial queue prevents API rate limit violations
- **Image Priority**: Best sales-ranked product (lowest SalesRank number) with image becomes primary_image
- **Single Music Search**: Use search_index: 'Music' for simplified, comprehensive coverage

---

## Implementation Notes

### Approach Taken
Successfully implemented Amazon Product API integration as first asynchronous DataImporter provider. The async pattern allows imports to continue without blocking on external API calls, with enrichment happening in background jobs.

### Key Files Created
```
app/lib/data_importers/music/album/providers/amazon.rb - Async provider
app/sidekiq/music/amazon_product_enrichment_job.rb - Background job
app/lib/services/music/amazon_product_service.rb - API and processing logic
app/lib/services/ai/tasks/amazon_album_match_task.rb - AI validation task
app/sidekiq/music/cover_art_download_job.rb - Cover art download job
```

### Key Files Modified
- `app/lib/data_importers/importer_base.rb` - Enhanced to support item-based imports and provider filtering
- `app/lib/data_importers/music/album/importer.rb` - Added Amazon provider and item-based import support
- `app/lib/data_importers/music/album/providers/music_brainz.rb` - Added item-based import support and cover art job trigger
- `config/initializers/sidekiq.rb` - Added serial queue capsule configuration
- `Gemfile` - Added down gem for image downloads and webmock for testing
- `test/test_helper.rb` - Added WebMock configuration

### Challenges Encountered
1. **GPT-5 Temperature Restrictions**: GPT-5 models only support temperature 1.0, required updating AI task
2. **Hash Key Type Mismatch**: AI results returned symbol keys but code expected string keys
3. **Image Validation Errors**: Active Storage requires file attachment before validating, fixed with build/attach/save pattern
4. **Provider Filtering**: Needed to implement provider selection for item-based imports
5. **Test WebMock Issues**: Real HTTP requests during tests caused timeouts, fixed with comprehensive WebMock stubs

### Deviations from Plan
- **AI Integration**: Used existing BaseTask pattern instead of custom chat classes
- **Cover Art Enhancement**: Added MusicBrainz Cover Art Archive integration for better images
- **Item-Based Imports**: Enhanced ImporterBase to support re-enriching existing albums
- **Provider Filtering**: Added `providers:` parameter for selective provider execution

### Code Examples
```ruby
# Async provider pattern
def populate(album, query:)
  return failure_result(errors: ["Album title required"]) if album.title.blank?
  ::Music::AmazonProductEnrichmentJob.perform_async(album.id)
  success_result(data_populated: [:amazon_enrichment_queued])
end

# Item-based import support
DataImporters::Music::Album::Importer.call(
  item: existing_album,
  providers: [:amazon]
)

# Serial queue configuration
config.capsule("serial") do |cap|
  cap.concurrency = 1
  cap.queues = %w[serial]
end
```

### Environment Variables Required
```
AMAZON_PRODUCT_API_ACCESS_KEY
AMAZON_PRODUCT_API_SECRET_KEY
AMAZON_PRODUCT_API_PARTNER_KEY
```

### Amazon API Resources Needed
```ruby
RESOURCES = [
  "ItemInfo.Title",
  "ItemInfo.ByLineInfo",
  "ItemInfo.Classifications",
  "ItemInfo.ContentInfo",
  "Images.Primary.Small",
  "Images.Primary.Medium",
  "Images.Primary.Large",
  "BrowseNodeInfo.WebsiteSalesRank",
  "Offers.Listings.Price",
  "Offers.Summaries.LowestPrice"
]
```

### Amazon API Call Example
```ruby
response = request.search_items(
  artist: 'Depeche Mode',
  title: 'Black Celebration',
  search_index: 'Music',
  resources: RESOURCES
)
```
Single search covers all music products (CDs, vinyl, digital, etc.)

### Example Response Structure
```ruby
[{
  "ASIN" => "B000002L9M",
  "BrowseNodeInfo" => {"WebsiteSalesRank" => {"SalesRank" => 4435}},
  "DetailPageURL" => "https://www.amazon.com/dp/B000002L9M?tag=shanesherman-20&linkCode=osi&th=1&psc=1",
  "Images" => {
    "Primary" => {
      "Large" => {"Height" => 500, "URL" => "https://m.media-amazon.com/images/I/51xU034w2+L._SL500_.jpg", "Width" => 497},
      "Medium" => {"Height" => 160, "URL" => "https://m.media-amazon.com/images/I/51xU034w2+L._SL160_.jpg", "Width" => 159},
      "Small" => {"Height" => 75, "URL" => "https://m.media-amazon.com/images/I/51xU034w2+L._SL75_.jpg", "Width" => 74}
    }
  },
  "ItemInfo" => {
    "ByLineInfo" => {
      "Contributors" => [{"Name" => "DEPECHE MODE", "Role" => "Artist"}],
      "Manufacturer" => {"DisplayValue" => "REPRISE USA"}
    },
    "Classifications" => {"Binding" => {"DisplayValue" => "Audio CD"}},
    "ExternalIds" => {
      "EANs" => {"DisplayValues" => ["0075992542920"]},
      "UPCs" => {"DisplayValues" => ["075992542920"]}
    },
    "ProductInfo" => {"ReleaseDate" => {"DisplayValue" => "1986-08-22T00:00:01Z"}},
    "Title" => {"DisplayValue" => "Black Celebration"}
  },
  "Offers" => {
    "Summaries" => [
      {"Condition" => {"Value" => "New"}, "LowestPrice" => {"Amount" => 14.77, "Currency" => "USD"}}
    ]
  }
}]
```

**Key Data Points for Processing:**
- `BrowseNodeInfo.WebsiteSalesRank.SalesRank` - Sort by this (lowest = highest ranked)
- `Images.Primary.Large.URL` - Primary image for download
- `ItemInfo.Title.DisplayValue` - Product title for AI matching
- `ItemInfo.ByLineInfo.Contributors` - Artist info for AI matching
- `DetailPageURL` - For ExternalLink creation
- `Offers.Summaries[].LowestPrice` - Price information

### Testing Approach
- Comprehensive test coverage for all components (21 importer tests, 24 Amazon-related tests)
- WebMock integration prevents real HTTP requests during testing
- Mock data includes proper MusicBrainz artist-credit structure for provider validation
- Tests cover async provider behavior, item-based imports, provider filtering, and error handling

### Performance Considerations
- Async provider returns immediately while enrichment happens in background
- Serial queue prevents API rate limiting violations (concurrency: 1)
- Image downloads only for albums without existing primary images
- AI validation prevents unnecessary external link creation

### Future Improvements
- Add more music browsing categories (vinyl, digital music subcategories)
- Support for additional Amazon marketplaces (UK, DE, etc.)
- Cache Amazon API responses to reduce API calls
- Batch processing for multiple album enrichments

### Lessons Learned
- Async provider pattern works well for external API integrations
- Item-based imports provide flexibility for re-enriching existing data
- WebMock essential for reliable testing of external API integrations
- GPT-5 temperature restrictions require careful AI task configuration
- Provider filtering enables targeted enrichment workflows

### Documentation Updated
- [x] Amazon provider class documentation created
- [x] Amazon Product Service documentation created
- [x] Amazon Album Match AI Task documentation created
- [x] Amazon Product Enrichment Job documentation created
- [x] Cover Art Download Job documentation created
- [x] ImporterBase documentation updated with item-based imports