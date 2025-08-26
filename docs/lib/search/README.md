# Search System

## Overview
The Greatest uses OpenSearch for advanced search and filtering capabilities across multiple media types. The search system provides full-text search, exact matching, and relationship queries through a structured indexing approach with background processing for optimal performance.

## Key Features
- **Full-text Search**: Accent and case-insensitive search using folding analyzers
- **Structured Data**: Index IDs and relationships for advanced filtering
- **Background Indexing**: Queue-based processing prevents blocking main application
- **Bulk Operations**: Efficient batch indexing and removal
- **Multi-media Support**: Extensible architecture for books, music, movies, and games

## System Architecture

### Core Components
1. **Base Index Class** (`Search::Base::Index`) - Common indexing functionality
2. **Media-specific Indexes** - Domain-specific search implementations
3. **Background Processing** - Sidekiq-based queue system for indexing
4. **Client Management** - Centralized OpenSearch connection handling

### Data Flow
```
Model Changes → SearchIndexRequest Queue → Background Job → OpenSearch Index
```

1. Model save/destroy triggers `SearchIndexable` concern callbacks
2. Callbacks create `SearchIndexRequest` records in database queue
3. `Search::IndexerJob` runs every 30 seconds to process queue
4. Job performs bulk index/unindex operations on OpenSearch
5. Queue records are cleaned up after processing

## Current Implementation

### Music Domain
The search system currently supports full music catalog search:

- **Artists** (`Search::Music::ArtistIndex`) - Artist name search with folding analyzer
- **Albums** (`Search::Music::AlbumIndex`) - Album titles with artist relationships
- **Songs** (`Search::Music::SongIndex`) - Song titles with artist and album relationships

### Index Fields
Each music index includes:
- **Text fields**: Full-text searchable names/titles
- **ID fields**: For exact relationship matching (`artist_id`, `album_ids`)
- **Category fields**: For filtering by genres/categories (`category_ids`)

## Background Processing

### SearchIndexable Concern
Models include `SearchIndexable` concern for automatic indexing:
```ruby
module SearchIndexable
  included do
    after_save :queue_for_indexing
    after_destroy :queue_for_unindexing
  end
end
```

### Indexer Job
`Search::IndexerJob` processes requests every 30 seconds:
- Groups requests by model type for bulk operations
- Deduplicates multiple requests for same item
- Handles up to 1000 requests per model type per run
- Cleans up processed queue records

## Performance Optimizations
- **Bulk APIs**: Uses OpenSearch bulk index/delete for efficiency
- **Request Deduplication**: Multiple changes to same item processed once
- **Memory Management**: Batched processing prevents memory bloat
- **Association Loading**: Only loads model relationships when needed by index

## Configuration Files

### Index Definitions
- [`base/index.md`](base/index.md) - Base index class with common functionality
- [`music/artist_index.md`](music/artist_index.md) - Artist search implementation
- [`music/album_index.md`](music/album_index.md) - Album search with artist relationships
- [`music/song_index.md`](music/song_index.md) - Song search with artist/album relationships

### Search Interfaces
- [`music/search/artist_general.md`](music/search/artist_general.md) - Artist search API
- [`music/search/album_general.md`](music/search/album_general.md) - Album search API  
- [`music/search/song_general.md`](music/search/song_general.md) - Song search API

### Infrastructure
- [`shared/client.md`](shared/client.md) - OpenSearch client management
- [`shared/utils.md`](shared/utils.md) - Common search utilities
- [`../../jobs/search/indexer_job.md`](../../jobs/search/indexer_job.md) - Background indexing job

### Base Components
- [`base/search.md`](base/search.md) - Base search functionality

## External Dependencies
- **OpenSearch**: Primary search engine
- **Redis**: Queue backend for Sidekiq
- **Sidekiq**: Background job processing
- **sidekiq-cron**: Scheduled job execution

## Future Expansion
The architecture is designed to support additional media types:
- Books search indexes
- Movies search indexes  
- Games search indexes
- Cross-media relationship queries

Each new domain can follow the same pattern of index classes, search interfaces, and background processing integration.

## Related Implementation Details
- Initial OpenSearch implementation: [Todo #024](../../todos/024-opensearch-improvements.md)
- Ranking system integration: [Todo #008](../../todos/008-ranking-configuration-model.md)