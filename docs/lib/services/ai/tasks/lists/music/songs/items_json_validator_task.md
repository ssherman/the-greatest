# Services::Ai::Tasks::Lists::Music::Songs::ItemsJsonValidatorTask

## Summary
AI task that validates MusicBrainz recording matches in Music::Songs::List items_json field. Identifies invalid matches where the original song and matched recording are different works (live vs studio, covers, remixes, etc.).

## Purpose
Ensures data quality by detecting common MusicBrainz matching errors:
- Live recordings matched with studio versions
- Cover versions matched with originals
- Different recordings by different artists with similar titles
- Remix or alternate versions matched with originals
- Artist name differences suggesting different works

## Location
`app/lib/services/ai/tasks/lists/music/songs/items_json_validator_task.rb`

## Parent Class
- Inherits from `Services::Ai::Tasks::BaseTask`

## Configuration

### Task Provider
- **Provider**: `:openai`
- **Model**: `gpt-5-mini` (cost-effective for validation)
- **Chat Type**: `:analysis`
- **Temperature**: `1.0` (GPT-5 models only support default)

### Response Format
- **Type**: `json_object` (structured output)
- **Schema**: `ResponseSchema` (OpenAI::BaseModel)

## Public Methods

### `#call`
Inherited from BaseTask. Validates all enriched songs in the list's items_json.

**Flow**:
1. Generates system message with validation criteria
2. Builds user prompt with numbered song matches
3. Sends to OpenAI for analysis
4. Receives structured response with invalid match numbers
5. Updates items_json with ai_match_invalid flags
6. Saves list and returns result

**Returns**: `Services::Ai::Result` with:
- `success: true/false`
- `data: {valid_count, invalid_count, total_count, reasoning}`
- `ai_chat: chat record`

## Private Methods

### `#task_provider`
Returns `:openai` - specifies OpenAI as the AI provider.

### `#task_model`
Returns `"gpt-5-mini"` - fast, cost-effective model for validation.

### `#chat_type`
Returns `:analysis` - categorizes chat for tracking purposes.

### `#temperature`
Returns `1.0` - default temperature (GPT-5 models require this).

### `#system_message`
Defines validation criteria for AI.

**Invalid Match Criteria**:
- Live recordings vs studio recordings
- Cover versions vs originals
- Different recordings with similar titles
- Remix/alternate versions vs originals
- Significant artist name differences

**Valid Match Criteria**:
- Same recording with minor formatting differences
- Different releases of the same recording
- Artist name variations (e.g., "The Beatles" vs "Beatles")
- Minor subtitle differences

**Returns**: String with detailed instructions

### `#user_prompt`
Builds numbered list of song matches for validation.

**Format**:
```
1. Original: "The Beatles - Come Together" → Matched: "The Beatles - Come Together"
2. Original: "John Lennon - Imagine" → Matched: "John Lennon - Imagine (Live)"
```

**Process**:
1. Extracts songs array from items_json
2. Filters to only enriched songs (mb_recording_id present)
3. Maps to numbered comparison format (1-based indexing)
4. Joins with newlines

**Returns**: String prompt for AI

### `#response_format`
Returns `{type: "json_object"}` - requests structured JSON response.

### `#response_schema`
Returns `ResponseSchema` class for parsing structured output.

### `#process_and_persist(provider_response)`
Updates items_json with validation results.

**Parameters**:
- `provider_response` - Hash with `:parsed` key containing response data

**Process**:
1. Extracts invalid array from response (1-based numbers)
2. Converts to 0-based indices for array access
3. Iterates through songs array
4. For enriched songs:
   - Adds `ai_match_invalid: true` if in invalid list
   - Removes `ai_match_invalid` key if valid (allows re-validation)
5. Saves updated items_json to database
6. Calculates validation counts
7. Returns success result with statistics

**Returns**: `Services::Ai::Result`

## Response Schema

### ResponseSchema (OpenAI::BaseModel)
Structured output format for AI responses.

**Fields**:
- `invalid` - `OpenAI::ArrayOf[Integer]` - Array of invalid match numbers (1-based)
- `reasoning` - `String` (optional) - Explanation of validation approach

**Example**:
```ruby
{
  invalid: [2, 5],
  reasoning: "Items 2 and 5 are live recordings matched with studio versions"
}
```

## Data Structure

### Input (items_json)
```ruby
{
  "songs" => [
    {
      "rank" => 1,
      "title" => "Come Together",
      "artists" => ["The Beatles"],
      "mb_recording_id" => "uuid-here",
      "mb_recording_name" => "Come Together",
      "mb_artist_names" => ["The Beatles"]
    }
  ]
}
```

### Output (items_json updated)
```ruby
{
  "songs" => [
    {
      "rank" => 1,
      "title" => "Imagine",
      "artists" => ["John Lennon"],
      "mb_recording_id" => "uuid-here",
      "mb_recording_name" => "Imagine (Live)",
      "mb_artist_names" => ["John Lennon"],
      "ai_match_invalid" => true  # Added by validator
    }
  ]
}
```

## Validation Logic

### Only Enriched Songs
Only validates songs with `mb_recording_id` present. Songs without MusicBrainz data are skipped.

### Index Conversion
AI receives 1-based numbering (natural for language models) but implementation uses 0-based array indices. Conversion happens in `process_and_persist`.

### Counter System
Maintains separate counter for enriched songs since prompt only includes those, but items_json array includes all songs. This allows correct flag placement.

### Re-validation
Running validation again removes previous `ai_match_invalid` flags for songs now deemed valid. This supports iterative refinement of matching rules.

## Invocation
Called by `Music::Songs::ValidateListItemsJsonJob` (Sidekiq background job).

```ruby
task = Services::Ai::Tasks::Lists::Music::Songs::ItemsJsonValidatorTask.new(parent: list)
result = task.call
```

## Related Components
- **Parent Model** - `Music::Songs::List` (must have items_json with enriched songs)
- **Enrichment Service** - `Services::Lists::Music::Songs::ItemsJsonEnricher` (populates MusicBrainz data)
- **Background Job** - `Music::Songs::ValidateListItemsJsonJob` (invokes this task)
- **Avo Action** - `Avo::Actions::Lists::Music::Songs::ValidateItemsJson` (triggers job)
- **Viewer Tool** - `Avo::ResourceTools::Lists::Music::Songs::ItemsJsonViewer` (displays results)

## Testing
Comprehensive test coverage in `test/lib/services/ai/tasks/lists/music/songs/items_json_validator_task_test.rb`:
- Configuration tests (provider, model, chat_type, temperature)
- System message content verification
- User prompt generation with enriched songs only
- Validation flag setting/removal
- Empty invalid array handling
- Re-validation scenario
- Index conversion (1-based to 0-based)
- Response schema structure

13 tests, all passing with Mocha mocking of OpenAI API.

## Pattern Source
Based on `Services::Ai::Tasks::Lists::Music::Albums::ItemsJsonValidatorTask` (task 054) with adaptations for song recordings vs album release groups.

## Performance
- Single API call per list (not per song)
- Uses fast gpt-5-mini model
- Efficient array iteration
- No N+1 queries (single update to items_json)
