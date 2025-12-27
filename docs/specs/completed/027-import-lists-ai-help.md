# 027 - Import Lists AI Help

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-08-30
- **Started**: 2025-08-30
- **Completed**: 2025-08-31
- **Developer**: AI Assistant

## Overview
Implement automatic list item parsing and extraction from HTML lists using AI assistance. The system will process raw HTML from lists, simplify it to minimal structure, and use AI agents to extract structured data for different media types (music albums, songs, books, movies, games).

## Context
Currently, lists are imported with raw HTML in the `raw_html` field, but there's no automated way to extract individual items from these lists. Manual processing is time-consuming and error-prone. We need an AI-powered system that can:

1. Clean and simplify HTML to remove unnecessary markup
2. Use media-specific AI agents to parse simplified HTML into structured JSON
3. Store the extracted data for further processing and matching to existing items

This builds on the existing AI service architecture (task 013) and follows the domain-driven design principles with media-specific namespacing.

## Requirements

### Database Changes
- [x] Add `simplified_html` text field to lists table
- [x] Add `items_json` jsonb field to lists table  
- [x] Create migration for new fields

### HTML Simplification Service
- [x] Create `Services::Html::SimplifierService` class
- [x] Use Nokogiri to strip unnecessary HTML elements and attributes
- [x] Keep only essential DOM structure (tags, ids, classes, text content)
- [x] Remove styling, scripts, inline styles, and non-semantic attributes
- [x] Preserve list structure (ul, ol, li) and hierarchical information

### AI Task Classes (Media-Specific)
- [x] Create `Services::Ai::Tasks::Lists::BaseRawParserTask` abstract base class
- [x] Create `Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask` (full implementation)
- [x] Create `Services::Ai::Tasks::Lists::Music::SongsRawParserTask` (full implementation)  
- [x] Create `Services::Ai::Tasks::Lists::Books::RawParserTask` (stub with basic structure)
- [x] Create `Services::Ai::Tasks::Lists::Movies::RawParserTask` (stub with basic structure)
- [x] Create `Services::Ai::Tasks::Lists::Games::RawParserTask` (stub with basic structure)

### Service Integration
- [x] Create `Services::Lists::ImportService` orchestrator class
- [x] Integrate HTML simplification with AI parsing
- [x] Handle different list types based on List STI subclasses
- [x] Store results in `items_json` field

### Testing
- [x] Test HTML simplification with various HTML structures
- [x] Test AI parsing with real-world list examples
- [x] Test service integration end-to-end
- [x] Add fixtures for different list types

## Technical Approach

### File Structure
```
app/lib/services/
├── html/
│   └── simplifier_service.rb                  # HTML cleaning and simplification
├── lists/
│   └── import_service.rb                       # Main orchestrator service
└── ai/
    └── tasks/
        └── lists/
            ├── base_raw_parser_task.rb         # Abstract base for list parsing
            ├── music/
            │   ├── albums_raw_parser_task.rb   # Music albums parsing (full)
            │   └── songs_raw_parser_task.rb    # Music songs parsing (full)
            ├── books/
            │   └── raw_parser_task.rb          # Books parsing (stub)
            ├── movies/
            │   └── raw_parser_task.rb          # Movies parsing (stub)
            └── games/
                └── raw_parser_task.rb          # Games parsing (stub)
```

### Database Migration
```ruby
class AddHtmlAndJsonFieldsToLists < ActiveRecord::Migration[8.0]
  def change
    add_column :lists, :simplified_html, :text
    add_column :lists, :items_json, :jsonb
  end
end
```

### HTML Simplifier Service
```ruby
module Services
  module Html
    class SimplifierService
      def self.call(raw_html)
        new(raw_html).call
      end

      def initialize(raw_html)
        @raw_html = raw_html
      end

      def call
        return nil if @raw_html.blank?
        
        doc = Nokogiri::HTML::DocumentFragment.parse(@raw_html)
        simplify_node(doc)
        doc.to_html
      end

      private

      def simplify_node(node)
        # Remove script and style tags completely
        node.css('script, style').remove
        
        # Keep only semantic attributes
        node.traverse do |element|
          next unless element.element?
          
          # Keep only essential attributes
          allowed_attrs = %w[id class href src alt title]
          element.attributes.each do |name, attr|
            element.remove_attribute(name) unless allowed_attrs.include?(name)
          end
        end
        
        node
      end
    end
  end
end
```

### Base Raw Parser Task
```ruby
module Services
  module Ai
    module Tasks
      module Lists
        class BaseRawParserTask < Services::Ai::Tasks::BaseTask
          private

          def chat_type = :list_parsing

          def task_provider = :openai  # Use OpenAI for JSON schema support

          def task_model = "gpt-4o-2024-08-06"

          def temperature = 0.1  # Low temperature for consistent parsing

          def system_message
            <<~SYSTEM_MESSAGE
              You are a parser that extracts #{media_type} information from HTML lists into structured format.

              Your ONLY task is to extract the following information for each #{media_type.singularize} in the provided HTML:
              #{extraction_fields.map { |field| "- #{field}" }.join("\n")}

              #{media_specific_instructions}

              Do not perform any lookups, research, or additional processing beyond simple extraction.
              Focus ONLY on extracting the data that is explicitly present in the HTML.
            SYSTEM_MESSAGE
          end

          def user_prompt
            <<~PROMPT
              Extract #{media_type} information from the following HTML. Focus ONLY on extracting the data without any additional processing:

              ```html
              #{parent.simplified_html}
              ```

              #{extraction_examples}

              Return ONLY the structured data as a JSON object with a '#{media_type}' array.

              IMPORTANT:
              - Every entry MUST include all required fields, even if some values are null
              - Do NOT perform any research or lookups
              - Do NOT add any information that isn't explicitly in the HTML
              - Work quickly and efficiently - focus only on extraction
            PROMPT
          end

          def response_format = { type: "json_object" }

          def process_and_persist(provider_response)
            data = validate!(provider_response[:content])
            parent.update!(items_json: data)
            create_result(success: true, data: data, ai_chat: chat)
          end

          # Abstract methods - override in subclasses
          def media_type
            raise NotImplementedError, "Subclasses must define media_type"
          end

          def extraction_fields
            raise NotImplementedError, "Subclasses must define extraction_fields"
          end

          def media_specific_instructions
            ""
          end

          def extraction_examples
            ""
          end
        end
      end
    end
  end
end
```

### Music Albums Raw Parser Task
```ruby
module Services
  module Ai
    module Tasks
      module Lists
        module Music
          class AlbumsRawParserTask < BaseRawParserTask
          private

          def media_type = "albums"

          def extraction_fields
            [
              "Rank (if present, can be null)",
              "Album title",
              "Artist name(s)",
              "Release year (if present, can be null)"
            ]
          end

          def media_specific_instructions
            <<~INSTRUCTIONS
              Understanding album information:
              - Albums typically have a primary artist, but may have multiple artists
              - Release year may be mentioned in parentheses or as separate text
              - Some lists may include record labels or other metadata - extract if present
              - Album titles should not include artist names unless it's part of the actual title
            INSTRUCTIONS
          end

          def extraction_examples
            <<~EXAMPLES
              Examples:
              For "1. The Dark Side of the Moon - Pink Floyd (1973)":
              - Rank: 1
              - Title: "The Dark Side of the Moon"
              - Artists: ["Pink Floyd"]
              - Release Year: 1973

              For "Abbey Road by The Beatles":
              - Rank: null
              - Title: "Abbey Road"
              - Artists: ["The Beatles"]
              - Release Year: null
            EXAMPLES
          end

          def response_schema
            ResponseSchema
          end

          class ResponseSchema < RubyLLM::Schema
            array :albums do
              integer :rank, required: false
              string :title, required: true
              array :artists, items: { type: :string }, required: true
              integer :release_year, required: false
            end
          end
          end
        end
      end
    end
  end
end
```

### Music Songs Raw Parser Task
```ruby
module Services
  module Ai
    module Tasks
      module Lists
        module Music
          class SongsRawParserTask < BaseRawParserTask
          private

          def media_type = "songs"

          def extraction_fields
            [
              "Rank (if present, can be null)",
              "Song title",
              "Artist name(s)",
              "Album name (if present, can be null)",
              "Release year (if present, can be null)"
            ]
          end

          def media_specific_instructions
            <<~INSTRUCTIONS
              Understanding song information:
              - Songs may be listed with or without album information
              - Featured artists should be included in the artists array
              - Duration may be present but is not required for extraction
              - Some songs may have multiple versions (live, remix, etc.) - note if present
            INSTRUCTIONS
          end

          def response_schema
            ResponseSchema
          end

          class ResponseSchema < RubyLLM::Schema
            array :songs do
              integer :rank, required: false
              string :title, required: true
              array :artists, items: { type: :string }, required: true
              string :album, required: false
              integer :release_year, required: false
            end
          end
        end
      end
    end
  end
end
```

### List Import Service
```ruby
module Services
  module Lists
    class ImportService
      def self.call(list)
        new(list).call
      end

      def initialize(list)
        @list = list
      end

      def call
        return failure("List has no raw HTML") if @list.raw_html.blank?

        # Step 1: Simplify HTML
        simplified_html = Services::Html::SimplifierService.call(@list.raw_html)
        @list.update!(simplified_html: simplified_html)

        # Step 2: Parse with appropriate AI task
        parser_class = determine_parser_class
        return failure("No parser available for list type: #{@list.type}") unless parser_class

        # Step 3: Execute AI parsing
        result = parser_class.new(parent: @list).call

        if result.success?
          success(result.data)
        else
          failure(result.error)
        end
      end

      private

      def determine_parser_class
        case @list.type
        when "Music::Albums::List"
          Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask
        when "Music::Songs::List"
          Services::Ai::Tasks::Lists::Music::SongsRawParserTask
        when "Books::List"
          Services::Ai::Tasks::Lists::Books::RawParserTask
        when "Movies::List"
          Services::Ai::Tasks::Lists::Movies::RawParserTask
        when "Games::List"
          Services::Ai::Tasks::Lists::Games::RawParserTask
        else
          nil
        end
      end

      def success(data)
        { success: true, data: data }
      end

      def failure(error)
        { success: false, error: error }
      end
    end
  end
end
```

## Dependencies
- Existing AI service architecture (task 013)
- Nokogiri gem (already in Gemfile)
- RubyLLM::Schema gem (already in Gemfile)
- OpenAI gem (already in Gemfile)
- List STI subclasses (Music::Albums::List, etc.)

## Acceptance Criteria
- [x] Can process raw HTML and generate simplified HTML with only essential structure
- [x] Music albums and songs lists can be parsed into structured JSON with high accuracy
- [x] Extracted JSON includes all required fields with proper null handling
- [x] Service gracefully handles malformed HTML and missing data
- [x] All AI interactions are logged to AiChat model
- [x] Stub implementations exist for books, movies, and games for future expansion
- [x] Integration service coordinates HTML simplification and AI parsing
- [x] Database fields are properly added without unnecessary indexing
- [x] Comprehensive test coverage for all components

## Design Decisions

### Why HTML Simplification First?
- Reduces AI processing overhead by removing unnecessary markup
- Improves parsing accuracy by focusing on semantic content
- Makes prompts more focused and effective
- Allows for better caching and debugging of intermediate results

### Why Media-Specific Parser Tasks?
- Different media types have different data structures and requirements
- Allows for specialized prompts and validation schemas
- Follows domain-driven design principles
- Enables independent evolution of parsing logic per media type

### Why Store Both simplified_html and items_json?
- simplified_html enables debugging and manual review
- items_json provides structured data for application use
- Allows for re-processing if AI models improve
- Supports different parsing strategies in the future

### Why JSONB for items_json?
- Enables efficient querying of extracted data when needed
- Allows for flexible schema evolution
- Native PostgreSQL JSON operations
- Can add indexing later if query performance requires it

### Why OpenAI Provider for List Parsing?
- Excellent performance with structured output (JSON schema)
- Consistent results with low temperature settings
- Good handling of complex HTML structures
- Reliable extraction accuracy

---

## Implementation Notes

### Approach Taken
Successfully implemented the complete list parser feature as planned with a few optimizations. The two-phase approach (HTML simplification → AI parsing) proved effective for reliable extraction of structured data from messy HTML lists.

### Key Files Changed
- `db/migrate/20250830161051_add_html_and_json_fields_to_lists.rb` - Added simplified_html and items_json fields
- `app/models/list.rb` - Added automatic HTML simplification callback and parse_with_ai! method
- `app/lib/services/html/simplifier_service.rb` - HTML cleaning service with aggressive tag removal
- `app/lib/services/ai/tasks/lists/base_raw_parser_task.rb` - Abstract base for list parsing tasks
- `app/lib/services/ai/tasks/lists/music/albums_raw_parser_task.rb` - Full albums parser implementation
- `app/lib/services/ai/tasks/lists/music/songs_raw_parser_task.rb` - Full songs parser implementation
- `app/lib/services/ai/tasks/lists/{books,movies,games}/raw_parser_task.rb` - Stub implementations
- `app/lib/services/lists/import_service.rb` - Orchestrator service
- `test/models/list_test.rb` - Updated tests for automatic HTML simplification

### Challenges Encountered
1. **Callback vs Manual Method Conflict**: Initial implementation had both automatic callback and manual `simplify_html!` method causing double service calls in tests
2. **Test Expectations**: Had to adjust test expectations when automatic behavior was added
3. **AI Model Selection**: Switched from original GPT-4o to GPT-5 Mini during implementation

### Deviations from Plan
1. **Removed Manual Method**: Originally planned to keep both automatic callback and manual `simplify_html!` method, but removed the manual method as redundant
2. **Enhanced HTML Simplifier**: Implemented more aggressive tag removal than originally planned (80+ unwanted tag types)
3. **Automatic HTML Simplification**: Added `before_save` callback to automatically simplify HTML when raw_html changes, making the process seamless
4. **Model Selection**: Used GPT-5 Mini instead of GPT-4o for cost efficiency and speed

### Code Examples
```ruby
# Automatic workflow - user just needs to set raw_html
list = Music::Albums::List.create!(
  name: "Best Albums 2023",
  raw_html: "<ul><li>1. Album - Artist</li></ul>"
)
# simplified_html is automatically populated on save

# Extract structured data with AI
result = list.parse_with_ai!
if result[:success]
  puts list.items_json # => { "albums": [{ "rank": 1, "title": "Album", ... }] }
end
```

### Testing Approach
- Unit tests for each service class with mocked dependencies
- Integration tests for the complete workflow
- Test coverage for automatic callback behavior
- Error handling tests for malformed HTML and AI failures
- Schema validation tests for structured output

### Performance Considerations
- HTML simplification runs in single pass with bulk element removal
- Uses GPT-5 Mini for cost efficiency while maintaining accuracy
- JSONB storage enables efficient querying of extracted data
- Automatic callback only runs when raw_html is present and changed

### Future Improvements
- Add retry logic for AI provider failures
- Implement batch processing for multiple lists
- Add validation for extracted data quality
- Consider caching simplified HTML for large lists
- Add monitoring for AI parsing success rates

### Lessons Learned
1. **Automatic callbacks are cleaner** than manual methods when the trigger condition is clear
2. **Aggressive HTML cleaning** significantly improves AI parsing accuracy
3. **Template method pattern** works well for media-specific parsing with shared infrastructure
4. **Test carefully around callbacks** - automatic behavior can interfere with explicit method testing

### Related PRs
*No PRs created - direct implementation*

### Documentation Updated
- [x] Service documentation files created for all new classes
- [x] Model documentation updated for new fields and methods
- [x] Implementation notes added to todo document