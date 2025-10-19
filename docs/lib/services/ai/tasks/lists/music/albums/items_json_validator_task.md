# Services::Ai::Tasks::Lists::Music::Albums::ItemsJsonValidatorTask

## Summary
AI task that validates MusicBrainz album matches in `items_json` field of Music::Albums::List records. Identifies invalid matches such as live albums matched with studio albums, tribute albums, compilations, or different works with similar titles.

## Inheritance
Inherits from `Services::Ai::Tasks::BaseTask`

## Purpose
After the items_json enricher adds MusicBrainz metadata to parsed albums, this task uses AI to validate that the matches are correct. Invalid matches are flagged with `ai_match_invalid: true` in the JSONB data for display in the viewer tool.

## Public Methods

### `.new(parent:, provider: nil, model: nil)`
Initializes the task with a Music::Albums::List record
- Parameters:
  - `parent` (Music::Albums::List) - The list containing items_json with enriched album data
  - `provider` (Symbol, optional) - AI provider to use (defaults to :openai)
  - `model` (String, optional) - AI model to use (defaults to "gpt-5-mini")
- Returns: Instance of ItemsJsonValidatorTask

### `#call`
Executes the validation task
- Returns: `Services::Ai::Result` with:
  - `success`: Boolean indicating if validation completed
  - `data`: Hash containing:
    - `valid_count`: Number of albums validated as correct matches
    - `invalid_count`: Number of albums flagged as invalid matches
    - `total_count`: Total number of enriched albums validated
    - `reasoning`: Optional explanation from AI
  - `ai_chat`: AiChat record for this validation
  - `error`: Error message if failed

## Configuration

### AI Provider
- **Provider**: OpenAI
- **Model**: gpt-5-mini (fast, cost-effective)
- **Temperature**: 1.0 (GPT-5 default)
- **Chat Type**: :analysis
- **Response Format**: JSON object with structured schema

### Response Schema
```ruby
class ResponseSchema < OpenAI::BaseModel
  required :invalid, OpenAI::ArrayOf[Integer], doc: "Array of item numbers that are invalid matches"
  required :reasoning, String, nil?: true, doc: "Brief explanation of validation approach"
end
```

## Validation Criteria

The AI identifies matches as INVALID when:
- **Live vs Studio**: Live albums matched with non-live albums
- **Tribute/Covers**: Tribute albums matched with originals
- **Different Works**: Different albums with similar titles
- **Compilation Mismatches**: Compilations matched with studio albums
- **Artist Mismatches**: Significant artist name differences suggesting different works

The AI identifies matches as VALID when:
- Same album with minor formatting differences
- Different editions (remastered, deluxe, etc.)
- Artist name variations (e.g., "The Beatles" vs "Beatles")
- Minor subtitle differences for the same work

## Data Processing

### Input Format
Processes enriched albums from `items_json["albums"]` with fields:
- `rank`, `title`, `artists`, `release_year` (original parsed data)
- `mb_release_group_id`, `mb_release_group_name`, `mb_artist_ids`, `mb_artist_names` (enriched data)

### Output Format
Updates `items_json["albums"]` by adding:
- `ai_match_invalid: true` - Added to albums flagged as invalid
- Removes flag from albums previously marked invalid but now validated as correct

### Numbering Conversion
- AI prompt uses 1-based numbering (more natural for AI models)
- Converts to 0-based indices for array access
- Only validates albums with `mb_release_group_id` present

## Dependencies
- `Services::Ai::Tasks::BaseTask` - Parent class providing AI infrastructure
- `OpenAI::BaseModel` - Structured output schema
- `Services::Ai::Result` - Result object for success/failure responses
- `AiChat` - ActiveRecord model for storing conversation history

## Usage Example

```ruby
# Validate a list with enriched album data
list = Music::Albums::List.find(123)
task = Services::Ai::Tasks::Lists::Music::Albums::ItemsJsonValidatorTask.new(parent: list)
result = task.call

if result.success?
  puts "Validated #{result.data[:total_count]} albums"
  puts "#{result.data[:invalid_count]} flagged as invalid"
  puts "Reasoning: #{result.data[:reasoning]}"
else
  puts "Validation failed: #{result.error}"
end
```

## Performance Considerations
- Single API call per list (not per album)
- Only validates albums with MusicBrainz data
- Fast model (gpt-5-mini) for cost efficiency
- Temperature locked at 1.0 (GPT-5 requirement)

## Related Classes
- `Services::Lists::Music::Albums::ItemsJsonEnricher` - Adds MusicBrainz data before validation
- `Music::Albums::ValidateListItemsJsonJob` - Sidekiq job that invokes this task
- `Avo::Actions::Lists::Music::Albums::ValidateItemsJson` - Admin action to trigger validation
