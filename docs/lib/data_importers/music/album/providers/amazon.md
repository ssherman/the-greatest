# DataImporters::Music::Album::Providers::Amazon

## Summary
Asynchronous DataImporter provider for Amazon Product API integration with Music::Album records. This is the first async provider in the system that launches a background job and returns success immediately, enabling non-blocking external API integration.

## Public Methods

### `#populate(album, query:)`
Validates album data and launches background Amazon enrichment job
- Parameters:
  - `album` (Music::Album) - Album to enrich with Amazon product data
  - `query` (ImportQuery) - Import query context (can be nil for item-based imports)
- Returns: ProviderResult with success status and `:amazon_enrichment_queued` data
- Side Effects: Launches `Music::AmazonProductEnrichmentJob` background job

## Validations
- Album must have a title (used for Amazon API search)
- Album must have at least one artist (used for Amazon API search)

## Dependencies
- `Music::AmazonProductEnrichmentJob` - Background job for actual Amazon API processing
- Inherits from `DataImporters::ProviderBase`

## Async Provider Pattern
This provider implements the async pattern where:
1. Provider validates inputs and returns immediately
2. Background job handles external API calls and data processing
3. Album import can continue without blocking on Amazon API
4. Enrichment happens asynchronously in serial queue

## Error Handling
- Returns failure result for missing album title or artists
- Catches and wraps any unexpected exceptions
- Background job handles Amazon API errors separately

## Background Processing
The actual Amazon integration happens in `Music::AmazonProductEnrichmentJob` which:
- Searches Amazon Product API using album artist and title
- Uses AI validation to confirm product matches
- Creates ExternalLink records for validated products
- Downloads primary images from best-ranked products
- Runs in serial queue to respect API rate limits