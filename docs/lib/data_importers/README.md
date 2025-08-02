# DataImporters Module

## Overview
The DataImporters module provides a flexible, extensible system for importing data from external sources across all media types (books, movies, games, music). It uses a strategy pattern with domain-agnostic base classes and domain-specific implementations.

## Architecture

### Strategy Pattern
The system follows the strategy pattern with three main components:
- **Importers**: Orchestrate the import process (find existing, create new, run providers, save)
- **Finders**: Search for existing records using external identifiers and intelligent matching
- **Providers**: Fetch and populate data from specific external sources (MusicBrainz, TMDB, etc.)

### Domain-Agnostic Base Classes
- `ImporterBase` - Main orchestration logic with provider aggregation
- `FinderBase` - Base class for finding existing records via identifiers
- `ProviderBase` - Base class for external data source integration
- `ImportQuery` - Factory for domain-specific query objects
- `ImportResult` - Aggregated results from all providers
- `ProviderResult` - Individual provider success/failure tracking

### Domain-Specific Implementations
Each media type has its own namespace with specific implementations:
```
DataImporters::Music::Artist::
  - Importer < ImporterBase
  - Finder < FinderBase
  - ImportQuery < ImportQuery
  - Providers::MusicBrainz < ProviderBase
```

## Usage

### Basic Import
```ruby
# Import an artist by name
result = DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")

if result.success?
  artist = result.item
  puts "Created artist: #{artist.name} (#{artist.kind})"
  puts "Data from: #{result.successful_providers.map(&:provider_name).join(', ')}"
else
  puts "Import failed: #{result.all_errors.join(', ')}"
end
```

### Import Flow
1. **Input**: Domain-specific query object with required parameters
2. **Find Existing**: Use identifier-based and AI-assisted matching
3. **Initialize**: Create new record if none found
4. **Populate**: All providers contribute data to the same item
5. **Validate & Save**: Save if valid and any provider succeeded
6. **Return Results**: Detailed ImportResult with provider feedback

## Key Features

### Provider Aggregation
Multiple providers can enrich the same record rather than stopping at first success. This allows combining data from different sources for more complete records.

### Intelligent Duplicate Detection
Uses external identifiers (MusicBrainz IDs, ISBNs, etc.) for reliable duplicate detection, falling back to name matching and future AI-assisted matching.

### Comprehensive Error Handling
Each provider can fail independently while still allowing the import to succeed if other providers work. Detailed error reporting shows exactly what went wrong.

### Type-Safe Input Validation
Domain-specific query objects ensure proper input validation and provide clear API contracts.

## Extensibility

### Adding New Providers
1. Create new provider class inheriting from `ProviderBase`
2. Implement `populate(item, query:)` method
3. Add to domain-specific importer's `providers` array

### Adding New Media Types
1. Create domain namespace (e.g., `DataImporters::Books::Book`)
2. Implement domain-specific `Importer`, `Finder`, and `ImportQuery` classes
3. Create provider classes for relevant external APIs

## Current Implementation
- **Music::Artist**: Complete implementation with MusicBrainz provider
- **Future domains**: Books, Movies, Games (architecture ready)

## Dependencies
- External API wrappers (Music::Musicbrainz, etc.)
- Identifier service for duplicate detection
- Domain models with validation