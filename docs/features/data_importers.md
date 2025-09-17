# DataImporters Feature

## Overview
The DataImporters system provides a flexible, extensible framework for importing and enriching data from external sources across all media types (books, movies, games, music). It uses a strategy pattern with domain-agnostic base classes and domain-specific implementations to handle complex data integration workflows.

## Architecture

### Core Design Principles
- **Strategy Pattern**: Separates concerns between orchestration (Importers), finding (Finders), and data fetching (Providers)
- **Domain-Agnostic Base Classes**: Shared logic for all media types
- **Incremental Saving**: Items saved after each successful provider for background job compatibility
- **Provider Aggregation**: Multiple providers can enrich the same record
- **Intelligent Duplicate Detection**: Uses external identifiers and fallback matching strategies

### System Components

#### Base Classes (Domain-Agnostic)
- **ImporterBase** - Main orchestration logic with provider aggregation and incremental saving
- **FinderBase** - Base class for finding existing records via external identifiers
- **ProviderBase** - Base class for external data source integration
- **ImportQuery** - Factory for domain-specific query objects with validation
- **ImportResult** - Aggregated results from all providers with success/failure tracking
- **ProviderResult** - Individual provider success/failure tracking

#### Domain-Specific Implementation Structure
```
DataImporters::Music::Artist::
  - Importer < ImporterBase
  - Finder < FinderBase
  - ImportQuery < ImportQuery
  - Providers::MusicBrainz < ProviderBase
```

### Key Features

#### Incremental Saving Architecture
Items are saved immediately after each successful provider execution, enabling:
- **Background Job Compatibility**: Items persisted before async providers run
- **Fast User Feedback**: Users see results after first provider, subsequent providers enhance over time
- **Reliable Updates**: Each provider's data saved immediately upon success
- **Failure Recovery**: First provider saves basic item, later providers enhance it

#### Force Providers Option
The `force_providers: true` parameter allows:
- Re-enriching existing items with new provider data
- Adding new providers to previously imported items
- Updating stale data from external sources

#### Provider Patterns

**Synchronous Provider:**
```ruby
class Providers::MusicBrainz < ProviderBase
  def populate(item, query:)
    # Fetch and populate data immediately
    # Save happens automatically after this returns success
    ProviderResult.new(success: true, provider_name: self.class.name)
  end
end
```

**Asynchronous Provider (Future):**
```ruby
class Providers::AmazonProduct < ProviderBase
  def populate(item, query:)
    # Launch background job
    AmazonProductEnrichmentJob.perform_async(item.id, query.to_h)
    # Return success immediately - job updates item later
    ProviderResult.new(success: true, provider_name: self.class.name)
  end
end
```

## Current Implementation

### Supported Media Types
- **Music::Artist** - Complete implementation with MusicBrainz provider
- **Music::Album** - Complete implementation with MusicBrainz provider  
- **Music::Release** - Multi-item implementation with MusicBrainz provider

### Provider Capabilities
- **MusicBrainz Integration**: Artist, album, and release data import
- **Identifier Management**: MusicBrainz IDs, ISNIs, ASINs with duplicate prevention
- **Category Population**: Genre and location categories from MusicBrainz tags
- **Relationship Handling**: Artist credits, album associations, release metadata

## Usage Examples

### Basic Import
```ruby
# Import an artist by name
result = DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")

if result.success?
  artist = result.item
  puts "Created artist: #{artist.name} (#{artist.kind})"
  puts "Data from: #{result.successful_providers.map(&:provider_name).join(', ')}"
end
```

### Re-enriching Existing Items
```ruby
# Run providers on existing items to add new data sources
result = DataImporters::Music::Artist::Importer.call(
  name: "Pink Floyd", 
  force_providers: true
)
```

### Import by External ID
```ruby
# Import using MusicBrainz ID for precise matching
result = DataImporters::Music::Artist::Importer.call(
  musicbrainz_id: "83d91898-7763-47d7-b03b-b92132375c47"
)
```

## Import Flow

### Standard Single-Item Import
1. **Input Validation**: Domain-specific query object validates parameters
2. **Find Existing**: Use external identifiers for reliable duplicate detection
3. **Early Return**: Skip providers if existing item found (unless force_providers: true)
4. **Initialize Item**: Create new record if none found
5. **Provider Execution**: Each provider contributes data, item saved after successful providers
6. **Result Aggregation**: Return detailed ImportResult with provider feedback

### Multi-Item Import (Releases)
1. **Input Validation**: Album provided as context
2. **Provider Orchestration**: Providers handle creation and persistence of multiple items
3. **Bulk Processing**: All releases for an album imported in single operation
4. **Incremental Support**: Skips existing releases for safe re-imports

## Error Handling

### Provider Isolation
- Individual provider failures don't stop the import
- Items saved after each successful provider if valid and changed
- Database save failures logged and gracefully handled
- Failed saves convert provider success to failure result

### Comprehensive Feedback
- Overall success/failure status
- Which providers succeeded/failed with detailed error messages
- Complete error aggregation for debugging
- Item persistence status tracking

## Extension Points

### Adding New Providers
1. Create provider class inheriting from `ProviderBase`
2. Implement `populate(item, query:)` method
3. Use `find_or_initialize_by` for identifiers to prevent duplicates
4. Add to domain-specific importer's `providers` array

### Adding New Media Types
1. Create domain namespace (e.g., `DataImporters::Books::Book`)
2. Implement domain-specific `Importer`, `Finder`, and `ImportQuery` classes
3. Create provider classes for relevant external APIs
4. Follow established patterns for consistency

## Performance Considerations

### Efficiency Features
- **Batch Operations**: Multi-item imports process multiple records efficiently
- **Duplicate Prevention**: External identifier lookup prevents redundant processing
- **Strategic Caching**: Provider results can be cached for repeated operations
- **Background Processing**: Async providers don't block user interactions

### Monitoring
- **Structured Logging**: Comprehensive logs for all operations
- **Error Tracking**: Provider-specific error reporting
- **Performance Metrics**: Import timing and success rates
- **Business Intelligence**: Track data enrichment coverage

## Future Enhancements

### Planned Features
- **Amazon Product API Integration**: Product data and pricing information
- **AI-Assisted Matching**: Fuzzy matching for ambiguous cases
- **Cross-Media Recommendations**: Link related content across domains
- **Data Quality Metrics**: Track and improve import accuracy

### Scalability Improvements
- **Provider Execution Tracking**: Monitor which providers have run on items
- **Selective Re-runs**: Target specific providers for updates
- **Bulk Import Operations**: Handle large datasets efficiently
- **Rate Limiting**: Respect external API constraints

## Related Documentation

For implementation details, see individual class documentation:
- [ImporterBase](../lib/data_importers/importer_base.md) - Core orchestration logic
- [FinderBase](../lib/data_importers/finder_base.md) - Duplicate detection strategies
- [ProviderBase](../lib/data_importers/provider_base.md) - External data integration patterns

For specific implementations:
- [Music::Artist::Importer](../lib/data_importers/music/artist/importer.md) - Artist import workflows
- [Music::Album::Importer](../lib/data_importers/music/album/importer.md) - Album import workflows
- [Music::Release::Importer](../lib/data_importers/music/release/importer.md) - Release import workflows