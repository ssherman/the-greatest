# Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask

## Summary
AI task that validates enriched ListItem matches using GPT to detect incorrect matches (live vs studio, covers, different artists, etc.). Used by the Song List Wizard to validate enriched items before import.

## Purpose
- Validates both OpenSearch and MusicBrainz matches against original list data
- Identifies invalid matches where the matched recording differs from the original
- Marks valid matches as `verified = true` for user confidence
- Clears `listable_id` on invalid OpenSearch matches

## Inheritance
Extends `Services::Ai::Tasks::BaseTask`

## Configuration

| Method | Value | Description |
|--------|-------|-------------|
| `task_provider` | `:openai` | Uses OpenAI API |
| `task_model` | `"gpt-5-mini"` | Model for validation |
| `chat_type` | `:analysis` | Analysis chat type |
| `temperature` | `1.0` | Default temperature |
| `response_format` | `{type: "json_object"}` | JSON response mode |

## Public Methods

### `#call`
Inherited from BaseTask. Executes the validation task.

**Returns**: `Services::Ai::Result` with:
- `success`: Boolean
- `data`: Hash with `valid_count`, `invalid_count`, `verified_count`, `total_count`, `reasoning`
- `ai_chat`: The AiChat record
- `error`: Error message (on failure)

## Private Methods

### `#enriched_items`
Returns ListItems that have enrichment data (either `listable_id`, `song_id`, or `mb_recording_id`).

**Returns**: Array of ListItem records

### `#user_prompt`
Builds a numbered list of Original → Matched pairs with source tags.

**Format**:
```
1. Original: "Artist - Title" → Matched: "Matched Name" [OpenSearch]
2. Original: "Artist - Title" → Matched: "Artist - Title" [MusicBrainz]
```

### `#process_and_persist(provider_response)`
Processes AI response and updates ListItems:
- Valid matches: Removes `ai_match_invalid`, sets `verified = true`
- Invalid matches: Sets `ai_match_invalid = true`, clears `listable_id` for OpenSearch matches

## Response Schema

```ruby
class ResponseSchema < OpenAI::BaseModel
  required :invalid, OpenAI::ArrayOf[Integer]  # Array of invalid item numbers
  required :reasoning, String, nil?: true       # Brief explanation
end
```

## Validation Criteria

**Invalid matches**:
- Live recordings matched with studio recordings
- Cover versions matched with originals
- Different recordings with similar titles
- Remix/alternate versions matched with originals
- Significant artist name differences

**Valid matches**:
- Same recording with minor formatting differences
- Different releases of same recording
- Artist name variations
- Minor subtitle differences

## Usage

```ruby
task = Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.new(parent: list)
result = task.call

if result.success?
  puts "Valid: #{result.data[:valid_count]}, Invalid: #{result.data[:invalid_count]}"
else
  puts "Error: #{result.error}"
end
```

## Dependencies
- `Services::Ai::Tasks::BaseTask`
- `OpenAI::BaseModel` for response schema
- Parent must be a `Music::Songs::List` with `list_items` association

## Related Files
- `app/lib/services/ai/tasks/lists/music/songs/items_json_validator_task.rb` - Similar task for Avo workflow
- `app/sidekiq/music/songs/wizard_validate_list_items_job.rb` - Job that calls this task
- `app/components/admin/music/songs/wizard/validate_step_component.rb` - UI component

## Differences from ItemsJsonValidatorTask
| Aspect | ItemsJsonValidatorTask | ListItemsValidatorTask |
|--------|----------------------|----------------------|
| Data source | `items_json["songs"]` | `list_items.metadata` |
| Validates | MusicBrainz only | OpenSearch + MusicBrainz |
| Sets verified | No | Yes |
| Clears invalid matches | No | Yes (for OpenSearch) |
| Used by | Avo workflow | Wizard workflow |
