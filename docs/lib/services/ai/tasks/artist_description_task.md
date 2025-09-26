# Services::Ai::Tasks::ArtistDescriptionTask

## Summary
AI task that generates descriptive content for music artists. Refactored from ArtistDetailsTask to focus solely on description generation, leaving factual metadata to MusicBrainz API.

## Associations
- Inherits from `Services::Ai::Tasks::BaseTask`
- Works with `Music::Artist` models as parent

## Public Methods

### `#system_message`
Returns the AI system message defining the copywriter persona and guidelines
- Returns: Hash with role and content keys
- Content: Cautious music copywriter instructions focusing on brief, factual descriptions

### `#user_prompt`
Generates the user prompt with artist context information
- Returns: String containing artist name, country, kind, formation/death dates
- Includes conditional context based on available artist metadata

### `#process_and_persist(data)`
Processes AI response and updates artist description if valid
- Parameters: data (Hash) - AI response data containing description, abstained status
- Returns: Boolean indicating success
- Side effects: Updates parent artist's description field if description is present

## Validations
- Validates AI response matches ArtistDescription schema
- Requires either description content or abstained status with reason

## Response Schema (ArtistDescription)
- `description` (String, optional) - Generated artist description
- `abstained` (Boolean) - Whether AI abstained from generating description
- `abstain_reason` (String, optional) - Reason for abstaining

## Configuration
- Temperature: 1.0 (GPT-5 requirement)
- Model: Configured via BaseTask
- Provider: Configured via BaseTask

## Dependencies
- RubyLLM gem for AI interaction
- Services::Ai::Tasks::BaseTask for common functionality
- Music::Artist model for data persistence

## Usage Pattern
```ruby
task = Services::Ai::Tasks::ArtistDescriptionTask.new(parent: artist)
result = task.call
# Updates artist.description if successful
```
