# Services::Ai::Tasks::Music::Songs::RecordingMatcherTask

## Summary

AI task that filters MusicBrainz candidate recordings to identify exact matches for a given song. Uses GPT-5-mini to analyze recording metadata and determine which candidates represent the same version of the song (not remixes, remasters, live versions, or covers).

## Usage

```ruby
# Filter candidates to exact matches
task = Services::Ai::Tasks::Music::Songs::RecordingMatcherTask.new(
  parent: song,
  candidates: musicbrainz_recordings
)
result = task.call

if result.success?
  exact_match_mbids = result.data[:exact_matches]
  reasoning = result.data[:reasoning]
end
```

## Initialization

### `#initialize(parent:, candidates:, provider: nil, model: nil)`

**Parameters:**
- `parent` (Music::Song) - The song being matched against
- `candidates` (Array<Hash>) - MusicBrainz recording data to filter
- `provider` (Symbol, optional) - AI provider to use (defaults to :openai)
- `model` (String, optional) - Model to use (defaults to "gpt-5-mini")

**Candidate Hash Structure:**
```ruby
{
  "id" => "mbid-uuid",
  "title" => "Song Title",
  "artist-credit" => [{"name" => "Artist Name"}],
  "first-release-date" => "1975-09-12",
  "disambiguation" => "optional context"
}
```

## Public Methods

### `#call`

Executes the AI task to filter candidates.

**Returns:** `Services::Ai::Result` with:
- `success?` (Boolean)
- `data` (Hash):
  - `exact_matches` (Array<String>) - MBIDs of recordings that match
  - `reasoning` (String) - AI's explanation of decisions
  - `excluded` (Array<Hash>) - Recordings excluded with reasons
- `ai_chat` (AiChat) - The chat record for audit

## AI Behavior

The task instructs the AI to match the song **as it is**, not necessarily the "original studio version":

- If song title indicates a remix (e.g., "Song (Club Mix)"), matches OTHER recordings of that SAME remix
- If song title indicates a live version, matches OTHER live recordings
- If song is the standard studio version, matches other studio recordings

**Included as matches:**
- Same version/mix as input song
- Different pressings or releases of same recording
- Mono/stereo variants

**Excluded:**
- Different mixes/remixes
- Live versions (if song is studio)
- Studio versions (if song is live)
- Remasters
- Cover versions
- Karaoke/instrumental versions
- Demo versions (unless song is a demo)

## Response Schema

```ruby
class ResponseSchema < OpenAI::BaseModel
  required :exact_matches, OpenAI::ArrayOf[String]
  required :reasoning, String, nil?: true
  required :excluded, OpenAI::ArrayOf[ExcludedRecording], nil?: true
end

class ExcludedRecording < OpenAI::BaseModel
  required :mbid, String
  required :reason, String
end
```

## Configuration

- **Provider:** OpenAI
- **Model:** gpt-5-mini
- **Chat Type:** :analysis
- **Response Format:** JSON object

## Dependencies

- `Services::Ai::Tasks::BaseTask` - Base class for AI tasks
- `OpenAI::BaseModel` - Schema definition
- `AiChat` model - Stores conversation history

## Related

- `Services::Music::Songs::RecordingIdEnricher` - Service that calls this task
- `Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask` - Similar pattern for list validation
