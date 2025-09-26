# Services::Ai::Tasks::AlbumDescriptionTask

## Summary
AI task that generates descriptive content for music albums. Creates meaningful descriptions using album metadata and artist context to provide rich, informative content for users.

## Associations
- Inherits from `Services::Ai::Tasks::BaseTask`
- Works with `Music::Album` models as parent

## Public Methods

### `#system_message`
Returns the AI system message defining the copywriter persona and guidelines
- Returns: Hash with role and content keys
- Content: Cautious music copywriter instructions focusing on brief, factual album descriptions

### `#user_prompt`
Generates the user prompt with album and artist context information
- Returns: String containing album title, artists, release year, categories
- Includes conditional context based on available album metadata
- Provides artist names for better contextual descriptions

### `#process_and_persist(data)`
Processes AI response and updates album description if valid
- Parameters: data (Hash) - AI response data containing description, abstained status
- Returns: Boolean indicating success
- Side effects: Updates parent album's description field if description is present

## Validations
- Validates AI response matches AlbumDescription schema
- Requires either description content or abstained status with reason

## Response Schema (AlbumDescription)
- `description` (String, optional) - Generated album description
- `abstained` (Boolean) - Whether AI abstained from generating description
- `abstain_reason` (String, optional) - Reason for abstaining

## Configuration
- Temperature: 1.0 (GPT-5 requirement)
- Model: Configured via BaseTask
- Provider: Configured via BaseTask

## Dependencies
- RubyLLM gem for AI interaction
- Services::Ai::Tasks::BaseTask for common functionality
- Music::Album model for data persistence
- Music::Artist associations for context

## Usage Pattern
```ruby
task = Services::Ai::Tasks::AlbumDescriptionTask.new(parent: album)
result = task.call
# Updates album.description if successful
```
