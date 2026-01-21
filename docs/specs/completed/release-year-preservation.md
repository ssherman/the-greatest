# Release Year Preservation for Song and Album Mergers

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-20
- **Started**: 2026-01-20
- **Completed**: 2026-01-20
- **Developer**: AI Agent (Claude Code)

## Overview
Enhance the `Music::Song::Merger` and `Music::Album::Merger` services to preserve the earliest (lowest non-null) `release_year` when merging records. Additionally, create rake tasks to backfill `release_year` data from MusicBrainz for songs and albums that have MusicBrainz identifiers.

**Goals**:
1. Merger services preserve the earliest release year when merging
2. Rake tasks to correct historical data by fetching the earliest release date from MusicBrainz

**Non-goals**:
- Changing merge target selection logic (still uses lowest ID)
- Merging other fields like `duration_secs` or `description`
- Processing records without MusicBrainz identifiers

## Context & Links
- Related tasks: `docs/specs/completed/067-song-merge-feature.md`, `docs/specs/completed/060-album-merge-feature.md`
- Source files (authoritative):
  - `web-app/app/lib/music/song/merger.rb`
  - `web-app/app/lib/music/album/merger.rb`
  - `web-app/lib/tasks/music/songs.rake`
  - `web-app/lib/tasks/music/albums.rake`
  - `web-app/app/lib/music/musicbrainz/search/recording_search.rb`
  - `web-app/app/lib/music/musicbrainz/search/release_group_search.rb`
- External docs: [MusicBrainz API Documentation](https://musicbrainz.org/doc/MusicBrainz_API)

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes - `release_year` already exists on both `music_songs` and `music_albums` tables as an integer field.

### Endpoints
N/A - Rake tasks only, no API endpoints.

### Behaviors (pre/postconditions)

#### Part 1: Merger Enhancement

**Preconditions**:
- Two song/album records exist with valid data
- At least one record should have a `release_year` value for the merge to have effect

**Postconditions**:
- After merge, target record's `release_year` is the minimum of:
  - Target's original `release_year` (if not null)
  - Source's `release_year` (if not null)
- If both are null, `release_year` remains null

**Logic** (pseudocode):
```
if source.release_year present AND (target.release_year nil OR source.release_year < target.release_year)
  target.release_year = source.release_year
end
```

**Edge cases**:
- Both null: No change
- Target has year, source null: No change (target's year preserved)
- Target null, source has year: Target gets source's year
- Source year < target year: Target updated to source's earlier year
- Source year >= target year: No change

#### Part 2: MusicBrainz Backfill Rake Tasks

**Task**: `music:songs:backfill_release_years`
**Task**: `music:albums:backfill_release_years`

**Preconditions**:
- Songs must have a `music_musicbrainz_recording_id` identifier
- Albums must have a `music_musicbrainz_release_group_id` identifier
- MusicBrainz API must be reachable

**Postconditions**:
- Records are updated if:
  - Current `release_year` is NULL and MusicBrainz has a valid year, OR
  - MusicBrainz returns an earlier year than the current non-null value
- Statistics printed showing total processed, updated, skipped, and errors

**MusicBrainz Data Source**:
- Songs: Recording lookup returns `first-release-date` field
- Albums: Release Group lookup returns `first-release-date` field

**Logic** (pseudocode):
```
mb_year = extract_year_from_musicbrainz(mbid)
return skip if mb_year is nil

if record.release_year is nil OR mb_year < record.release_year
  record.release_year = mb_year
  return updated
else
  return skipped
end
```

**Edge cases & failure modes**:
- MusicBrainz returns null/empty date: Skip record
- MusicBrainz API error: Log error, continue to next record
- Invalid MBID format: Skip record with warning
- MusicBrainz returns date format without year: Skip record

### Non-Functionals
- **Rate Limiting**: No delay between API calls (user has self-hosted MusicBrainz instance)
- **Scope**: Only process records with MusicBrainz identifiers
- **Performance**: Use `find_each` for batch processing to avoid memory issues
- **Dry-run mode**: Support `DRY_RUN=true` environment variable
- **Progress**: Print progress every 100 records

## Acceptance Criteria

### Part 1: Merger Enhancement

#### Song Merger
- [x] `Music::Song::Merger` preserves earliest release_year when merging
- [x] Test: Source year earlier than target → target updated
- [x] Test: Source year later than target → target unchanged
- [x] Test: Source null, target has year → target unchanged
- [x] Test: Source has year, target null → target gets source year
- [x] Test: Both null → remains null

#### Album Merger
- [x] `Music::Album::Merger` preserves earliest release_year when merging
- [x] Test: Source year earlier than target → target updated
- [x] Test: Source year later than target → target unchanged
- [x] Test: Source null, target has year → target unchanged
- [x] Test: Source has year, target null → target gets source year
- [x] Test: Both null → remains null

### Part 2: MusicBrainz Backfill

#### Song Backfill Task
- [x] Task `music:songs:backfill_release_years` exists
- [x] Only processes songs with `music_musicbrainz_recording_id` identifier
- [x] Looks up recording in MusicBrainz by MBID
- [x] Updates `release_year` if current is NULL and MusicBrainz has valid year
- [x] Updates `release_year` if MusicBrainz year is earlier than current non-null year
- [x] Skips if MusicBrainz year >= current year (no improvement)
- [x] Supports `DRY_RUN=true` for testing
- [x] Prints summary statistics (total, updated, skipped, errors)
- [x] Continues processing on individual record failures

#### Album Backfill Task
- [x] Task `music:albums:backfill_release_years` exists
- [x] Only processes albums with `music_musicbrainz_release_group_id` identifier
- [x] Looks up release group in MusicBrainz by MBID
- [x] Updates `release_year` if current is NULL and MusicBrainz has valid year
- [x] Updates `release_year` if MusicBrainz year is earlier than current non-null year
- [x] Skips if MusicBrainz year >= current year (no improvement)
- [x] Supports `DRY_RUN=true` for testing
- [x] Prints summary statistics (total, updated, skipped, errors)
- [x] Continues processing on individual record failures

### Golden Examples

#### Merger Example
```text
Input:
  Target Song: ID 100, release_year: 1985
  Source Song: ID 200, release_year: 1983

Output (after merge):
  Target Song: ID 100, release_year: 1983  # Updated to earlier year
  Source Song: (deleted)
```

#### Backfill Task Example
```text
$ bin/rails music:songs:backfill_release_years

Backfilling release years from MusicBrainz...
Scope: Only songs with MusicBrainz recording IDs
Mode: LIVE (updates will be applied)
================================================================================
  Processing song #1234 "Yesterday" (The Beatles)...
    Current: 1965, MusicBrainz: 1965 → SKIPPED (not earlier)
  Processing song #5678 "Hey Jude" (The Beatles)...
    Current: 1970, MusicBrainz: 1968 → UPDATED (2 years earlier)
  Processing song #9012 "Let It Be" (The Beatles)...
    Current: nil, MusicBrainz: 1970 → UPDATED (was null)
  Processing song #1111 "Come Together" (The Beatles)...
    Current: nil, MusicBrainz: nil → SKIPPED (no MusicBrainz data)
  Processed 100 songs...
================================================================================
Backfill complete!
  Total processed: 500
  Updated: 95
  Skipped (not earlier or no MB data): 400
  Errors: 5
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.
- Merger changes must be within existing transaction scope.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → collect rake task patterns from `lib/tasks/music/`
2) codebase-analyzer → verify MusicBrainz API response structure for recordings/release-groups
3) web-search-researcher → MusicBrainz API `first-release-date` field documentation if needed
4) technical-writer → update merger documentation

### Test Seed / Fixtures
- Existing song/album fixtures with varying `release_year` values
- Create identifiers with MusicBrainz recording/release-group IDs for testing

---

## Implementation Notes (living)
- Approach taken: Added `merge_release_year` private method to both merger services, called within `merge_all_associations`
- Important decisions:
  - Changed `target.touch` to `target.save! if target.changed?` followed by `touch unless saved_changes?` to ensure release_year changes are persisted properly
  - Rake tasks use `find_each` for memory efficiency and include progress indicators every 100 records

### Key Files Touched (paths only)
- `web-app/app/lib/music/song/merger.rb`
- `web-app/app/lib/music/album/merger.rb`
- `web-app/lib/tasks/music/songs.rake`
- `web-app/lib/tasks/music/albums.rake`
- `web-app/test/lib/music/song/merger_test.rb`
- `web-app/test/lib/music/album/merger_test.rb`

### Challenges & Resolutions
- Needed to change from `touch` to conditional `save!` to ensure release_year changes persist within transaction

### Deviations From Plan
- None

## Acceptance Results
- Date: 2026-01-20
- Verifier: AI Agent (Claude Code)
- Tests: 51 runs, 127 assertions, 0 failures, 0 errors (merger tests including 10 new release_year tests)

## Future Improvements
- Add `LIMIT=N` environment variable to process only N records
- Add `OFFSET=N` to resume from a specific position
- Consider background job for very large datasets
- Add Slack notification on completion

## Related PRs
- #

## Documentation Updated
- [x] `docs/lib/music/song/merger.md` - Added release_year preservation section
- [x] `docs/lib/music/album/merger.md` - Added release_year preservation section
