# MusicBrainz Recording ID Enrichment for Songs

## Status
- **Status**: Complete
- **Priority**: Medium
- **Created**: 2026-01-24
- **Started**: 2026-01-25
- **Completed**: 2026-01-25
- **Developer**: Claude

## Overview

Build a background job that enriches songs with additional MusicBrainz recording IDs by searching for all recordings matching the song's title and artist(s), then using AI to filter for exact matches (same song, not remixes/remasters/special editions/covers).

**Goal**: Reduce manual effort spent googling and looking up original release dates by automatically finding all valid MusicBrainz recording IDs for a song.

**Two-step process**:
1. **This spec**: Enrich songs with all valid MusicBrainz recording IDs → populates `identifiers` table
2. **Existing**: Run `music:songs:backfill_release_years` rake task → sets `release_year` to the lowest year from all linked recording IDs

**Typical workflow for ranked songs**:
```bash
# Step 1: Enrich ranked songs with additional MusicBrainz recording IDs
RANKED_ONLY=true bin/rails music:songs:enrich_recording_ids

# Step 2: Set release_year to lowest from all identifiers
RANKED_ONLY=true bin/rails music:songs:backfill_release_years
```

**Scope**:
- Search MusicBrainz API for all recordings matching song title + artist
- Use AI to filter results to exact matches only
- Create `Identifier` records for each valid match
- Does NOT update `release_year` directly (existing rake task handles that)

**Non-goals**:
- Changing the initial import process
- Directly updating release_year (existing task handles this)
- Building a UI (can be added later)

## Context & Links

- Related tasks/phases:
  - Existing `music:songs:backfill_release_years` rake task - sets release_year from identifiers
- Source files (authoritative):
  - `lib/tasks/music/songs.rake:172-276` - existing backfill task (will be modified to add `RANKED_ONLY`)
  - `app/lib/music/musicbrainz/search/recording_search.rb` - MB search client
  - `app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb` - AI task pattern
  - `app/models/identifier.rb` - polymorphic identifier model (see `docs/models/identifier.md`)
  - `app/models/music/song.rb` - Song model with `ranked_items` association
- External docs:
  - MusicBrainz API: https://musicbrainz.org/doc/MusicBrainz_API
  - MusicBrainz Recording: https://musicbrainz.org/doc/Recording

## Problem Analysis

### Current State

The existing `backfill_release_years` rake task already:
- Finds songs with MusicBrainz recording IDs in the `identifiers` table
- Looks up ALL linked MBIDs for each song
- Finds the minimum `first-release-date` across all MBIDs
- Updates `song.release_year` to the lowest year

**The gap**: Songs often only have 1 recording ID (from initial import), which may be a remaster/re-release with a later date. We need to find and add ALL valid recording IDs so the existing task can pick the earliest.

### Why Songs Have Incorrect Release Years

1. **Initial import matches wrong recording**: Search returns a 2020 remaster as the top result instead of the 1990 original
2. **Only one MBID stored**: Even if the correct original exists in MusicBrainz, we don't have its ID linked

### Solution: Enrich with More Recording IDs

For each song:
1. Search MusicBrainz by artist + title to find ALL candidate recordings
2. Use AI to filter: keep only exact matches (same song, same artist, not remixes/covers/special editions)
3. Create `Identifier` records for each valid match
4. Run existing `backfill_release_years` task to set the lowest year

## Interfaces & Contracts

### Domain Model

Uses existing `Identifier` model with type `music_musicbrainz_recording_id`. No schema changes required.

### New Service: `Services::Music::Songs::RecordingIdEnricher`

```ruby
# Enriches a song with additional MusicBrainz recording IDs
# Returns enrichment result with new identifiers created
Services::Music::Songs::RecordingIdEnricher.call(
  song: song,
  dry_run: false
)
# => { success: true, candidates_found: 15, exact_matches: 3,
#      new_identifiers_created: 2, existing_identifiers: 1 }
```

### New AI Task: `Services::Ai::Tasks::Music::Songs::RecordingMatcherTask`

Input: Song metadata + array of MusicBrainz candidate recordings
Output: Array of recording MBIDs that are exact matches

### New Rake Task: `music:songs:enrich_recording_ids`

```bash
# Run on all songs
bin/rails music:songs:enrich_recording_ids

# Dry run (preview only)
DRY_RUN=true bin/rails music:songs:enrich_recording_ids

# Only process ranked songs (songs with ranked_items)
RANKED_ONLY=true bin/rails music:songs:enrich_recording_ids

# Combine options
DRY_RUN=true RANKED_ONLY=true bin/rails music:songs:enrich_recording_ids
```

### Modified Rake Task: `music:songs:backfill_release_years`

Add `RANKED_ONLY` support to the existing task:

```bash
# Existing behavior (all songs with MBIDs)
bin/rails music:songs:backfill_release_years

# NEW: Only process ranked songs
RANKED_ONLY=true bin/rails music:songs:backfill_release_years

# Combine with dry run
DRY_RUN=true RANKED_ONLY=true bin/rails music:songs:backfill_release_years
```

### Schemas (JSON)

**AI Task Input:**
```json
{
  "song": {
    "title": "Johnny B. Goode",
    "artists": ["Chuck Berry"],
    "current_release_year": 2017
  },
  "candidates": [
    {
      "mbid": "aaa-111",
      "title": "Johnny B. Goode",
      "artist_credit": "Chuck Berry",
      "first_release_date": "1958-03-31",
      "disambiguation": ""
    },
    {
      "mbid": "bbb-222",
      "title": "Johnny B. Goode (live)",
      "artist_credit": "Chuck Berry",
      "first_release_date": "1972-06-15",
      "disambiguation": "live at Fillmore"
    },
    {
      "mbid": "ccc-333",
      "title": "Johnny B. Goode (2017 remaster)",
      "artist_credit": "Chuck Berry",
      "first_release_date": "2017-01-01",
      "disambiguation": "remastered"
    }
  ]
}
```

**AI Task Response Schema:**
```json
{
  "type": "object",
  "required": ["exact_matches", "reasoning"],
  "properties": {
    "exact_matches": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Array of MBIDs that are exact matches for the original song"
    },
    "reasoning": {
      "type": "string",
      "description": "Explanation of filtering decisions"
    },
    "excluded": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "mbid": { "type": "string" },
          "reason": { "type": "string" }
        }
      },
      "description": "Recordings excluded and why"
    }
  }
}
```

### Behaviors (pre/postconditions)

**Preconditions:**
- Song has artists associated (for search queries)

**Postconditions:**
- `Identifier` records created for each exact match (type: `music_musicbrainz_recording_id`)
- Duplicate identifiers not created (uses `find_or_create_by`)
- Song's `release_year` NOT modified (existing rake task handles this separately)

**Edge cases & failure modes:**
- No MusicBrainz results found → skip song, log as "no candidates"
- AI returns empty matches → skip song, log for review
- API rate limits → job pauses and retries
- Song has no artists → skip song (cannot search reliably)

### Non-Functionals

- **Performance**: Process max 100 songs per job run
- **Rate limiting**: Respect MusicBrainz 1 req/sec limit (existing client handles this)
- **Idempotency**: Running twice produces same result (find_or_create)
- **Audit trail**: Log enrichment results for each song

## Acceptance Criteria

- [x] `RecordingIdEnricher` service searches MB by artist MBID (preferred) or name (fallback)
- [x] AI task filters candidates to exact matches for the SAME VERSION (analyzes song title to determine if it's a remix/live/standard version)
- [x] `Identifier` records created for each exact match
- [x] Existing identifiers not duplicated (uses `find_or_create_by!`)
- [x] Rake task processes songs in batches with progress output
- [x] `DRY_RUN=true` shows what would be created without applying
- [x] `RANKED_ONLY=true` limits to songs with ranked_items
- [x] After running, `backfill_release_years` task can use new identifiers to set correct year
- [x] **Existing task updated**: `backfill_release_years` also supports `RANKED_ONLY=true`

### Golden Examples

**Example 1: Classic song with multiple recordings**
```text
Input:
  Song: "Johnny B. Goode" by Chuck Berry
  Current release_year: 2017
  Current identifiers: [ccc-333]

MusicBrainz search returns 15 candidates, including:
  - aaa-111: "Johnny B. Goode" (1958) - original studio
  - bbb-222: "Johnny B. Goode (live)" (1972) - live version
  - ccc-333: "Johnny B. Goode (2017 remaster)" (2017) - remaster
  - ddd-444: "Johnny B. Goode" (1958) - mono mix
  - eee-555: "Johnny B. Goode" (1964) - re-recording

AI Output:
  exact_matches: ["aaa-111", "ddd-444", "eee-555"]
  reasoning: "Selected original studio recordings. Excluded bbb-222 (live version)
              and ccc-333 (remaster - not original recording)."
  excluded: [
    { mbid: "bbb-222", reason: "live version" },
    { mbid: "ccc-333", reason: "remaster" }
  ]

Result:
  - 2 new Identifiers created: aaa-111, ddd-444
  - eee-555 matches ccc-333's song but is a re-recording, AI includes it
  - ccc-333 already existed, not duplicated

After running backfill_release_years:
  - Song release_year updated from 2017 → 1958 (lowest from aaa-111 or ddd-444)
```

**Example 2: Standard studio version (exclude remixes)**
```text
Input:
  Song: "Enjoy the Silence" by Depeche Mode
  Current release_year: 2004

MusicBrainz search returns 50+ candidates, including:
  - Recording 1: "Enjoy the Silence" (1990) - original single
  - Recording 2: "Enjoy the Silence (Hands and Feet mix)" (1990) - remix
  - Recording 3: "Enjoy the Silence (2004 remaster)" (2004) - remaster
  - Recording 4: "Enjoy the Silence" (1990) - album version

AI Output:
  exact_matches: ["Recording 1 mbid", "Recording 4 mbid"]
  reasoning: "Song is the standard version. Selected original studio versions.
              Excluded remixes and remasters."
  excluded: [
    { mbid: "...", reason: "remix (Hands and Feet mix)" },
    { mbid: "...", reason: "remaster" }
  ]

Result:
  - 2 Identifiers created for original versions
  - After backfill_release_years: release_year → 1990
```

**Example 3: Song IS a remix (match same remix only)**
```text
Input:
  Song: "Blue Monday (1988 remix)" by New Order
  Current release_year: 2015

MusicBrainz search returns 30+ candidates, including:
  - Recording 1: "Blue Monday" (1983) - original 12"
  - Recording 2: "Blue Monday (1988 remix)" (1988) - the 1988 remix
  - Recording 3: "Blue Monday (1988 remix)" (1995) - same remix, compilation
  - Recording 4: "Blue Monday (Hardfloor mix)" (1995) - different remix

AI Output:
  exact_matches: ["Recording 2 mbid", "Recording 3 mbid"]
  reasoning: "Song title indicates this is the 1988 remix specifically.
              Matched only recordings of that same remix. Excluded the 1983
              original and other remixes."
  excluded: [
    { mbid: "...", reason: "original version, not the 1988 remix" },
    { mbid: "...", reason: "different remix (Hardfloor mix)" }
  ]

Result:
  - 2 Identifiers created for 1988 remix versions
  - After backfill_release_years: release_year → 1988
```

**Example 4: Song IS a live version (match same live recording)**
```text
Input:
  Song: "Comfortably Numb (live)" by Pink Floyd
  Current release_year: 2000

MusicBrainz search returns candidates including:
  - Recording 1: "Comfortably Numb" (1979) - studio original
  - Recording 2: "Comfortably Numb (live)" (1988) - Delicate Sound of Thunder
  - Recording 3: "Comfortably Numb (live)" (1995) - Pulse
  - Recording 4: "Comfortably Numb (live)" (2000) - Is There Anybody Out There?

AI Output:
  exact_matches: ["Recording 2 mbid", "Recording 3 mbid", "Recording 4 mbid"]
  reasoning: "Song is a live version. Matched all live recordings. Cannot
              determine which specific live performance without more context,
              so including all live versions to get earliest live release."
  excluded: [
    { mbid: "...", reason: "studio version, song is live" }
  ]

Result:
  - 3 Identifiers created for live versions
  - After backfill_release_years: release_year → 1988 (earliest live release)
```

### AI Task System Message (Reference)

```ruby
# reference only - actual implementation may vary
def system_message
  <<~SYSTEM
    You are a music expert identifying which MusicBrainz recordings are exact
    matches for a given song.

    Given a song's metadata and MusicBrainz candidate recordings, identify which
    recordings represent the SAME VERSION of the song.

    IMPORTANT: Match the song AS IT IS, not necessarily the "original studio version."
    - If the song title indicates it's a remix (e.g., "Song (Club Mix)"), match OTHER
      recordings of that SAME remix, not the original.
    - If the song title indicates it's a live version, match OTHER live recordings
      of that same performance/tour.
    - If the song is the standard studio version, match other studio recordings.

    INCLUDE as exact matches:
    - Recordings that are the same version/mix as the input song
    - Different pressings or releases of the same recording
    - Mono/stereo variants of the same recording

    EXCLUDE (not the same version):
    - Different mixes/remixes than what the song title indicates
    - Live versions (if the song is a studio version)
    - Studio versions (if the song is a live version)
    - Remasters (same recording, different release - exclude to avoid confusion)
    - Cover versions by other artists
    - Karaoke/instrumental versions
    - Demo versions (unless the song is specifically a demo)

    Return the MBIDs of recordings that match the same version as the input song.
  SYSTEM
end
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Use existing MusicBrainz client and AI task patterns.
- Does NOT modify release_year directly.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → examine existing AI task implementations
2) codebase-analyzer → verify MusicBrainz client search capabilities

### Test Seed / Fixtures
- `spec/fixtures/musicbrainz/recording_search_results.json` - mock search responses
- Factory: `music_song` with various scenarios

---

## Implementation Notes (living)

- Approach taken: Followed existing AI task patterns (BaseTask, OpenAI::BaseModel schemas) and service patterns
- Important decisions:
  - **Use artist MusicBrainz ID when available** for more accurate search (falls back to name if no MBID)
  - Searches all artist MBIDs if multiple exist, deduplicates results
  - 50 candidates limit for search results
  - Always re-run on each execution (no skip for already-enriched songs)
  - Use `find_or_create_by!` for race-condition-safe identifier creation
  - No custom temperature for AI task (GPT-5 doesn't support it)

### Key Files Touched (paths only)
- `app/lib/services/music/songs/recording_id_enricher.rb` (new)
- `app/lib/services/ai/tasks/music/songs/recording_matcher_task.rb` (new)
- `lib/tasks/music/songs.rake` (modified - add `enrich_recording_ids` task, add `RANKED_ONLY` to `backfill_release_years`, fix rescue block bug)
- `test/lib/services/music/songs/recording_id_enricher_test.rb` (new)
- `test/lib/services/ai/tasks/music/songs/recording_matcher_task_test.rb` (new)

### Challenges & Resolutions
- Schema class ordering: `ExcludedRecording` had to be defined before `ResponseSchema` that references it
- Pre-existing bug in `backfill_release_years`: Fixed rescue block to properly handle exceptions per-iteration
- Artist search accuracy: Improved by using artist MusicBrainz ID instead of name-based search when available

### Deviations From Plan
- Fixed pre-existing bug in `backfill_release_years` task (rescue block was incorrectly placed)
- Enhanced search to use artist MBID when available (more accurate than spec's name-based search)

## Acceptance Results
- Date: 2026-01-25
- All 3200 tests pass
- Rake tasks verified: `bin/rails -T music:songs` shows all tasks

## Future Improvements
- Admin UI to trigger enrichment for individual songs
- Integration with list wizard to enrich during import
- Option to use Works API for more comprehensive candidate search
- Sidekiq job for background processing of large batches

## Related PRs
- #

## Documentation Updated
- [x] `docs/services/music/songs/recording_id_enricher.md`
- [x] `docs/services/ai/tasks/music/songs/recording_matcher_task.md`
