# DataImporters::ImportQuery

## Summary
Base factory class for creating domain-specific query objects. Provides type-safe input validation and consistent API contracts for import operations.

## Public Methods

### `.for(domain:, **params)`
Factory method to create domain-specific query objects (future implementation)
- Parameters:
  - domain (Symbol) - Media domain (:music, :books, :movies, :games)
  - params (Hash) - Domain-specific parameters
- Returns: Domain-specific ImportQuery subclass instance
- Purpose: Centralized query object creation

## Usage Pattern
This class serves as a base for domain-specific query objects. Each domain implements its own validation and parameter handling:

```ruby
module DataImporters
  module Music
    module Artist
      class ImportQuery < DataImporters::ImportQuery
        attr_reader :name, :options

        def initialize(name:, **options)
          @name = name
          @options = options
        end

        def valid?
          name.present?
        end

        def to_h
          { name: name, options: options }
        end
      end
    end
  end
end
```

## Query Object Responsibilities
Domain-specific query objects should:
1. **Validate required parameters** - Ensure all mandatory fields are present
2. **Type check inputs** - Validate parameter types and formats
3. **Provide clear API** - Consistent interface across domains
4. **Enable serialization** - Support conversion to/from hash format

## Validation Requirements
All query objects must implement:
- `valid?` method returning boolean
- Clear validation rules for required vs optional parameters
- Helpful error messages for invalid inputs

## Common Parameters
Typical parameters across domains:
- **Name/Title** - Primary identifier for search
- **Options hash** - Additional search criteria or import preferences
- **Force flags** - Override duplicate detection or update existing records
- **Provider preferences** - Specify which external sources to use

## Benefits
- **Type safety** - Catch parameter errors early
- **Consistent API** - Same interface pattern across all domains
- **Validation centralization** - All input validation in one place
- **Documentation** - Clear parameter contracts for each domain

## Future Enhancements
- Automatic parameter coercion (string to integer, etc.)
- Complex validation rules (mutually exclusive options)
- Parameter sanitization and normalization
- Multi-step query building for complex imports

## Dependencies
- Domain-specific validation logic
- Rails validation helpers (present?, etc.)
- Type checking utilities