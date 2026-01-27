# Fix Release Year Correction: Remove release_year from AI Prompt

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-01-27
- **Started**: 2026-01-27
- **Completed**: 2026-01-27
- **Developer**: Claude

## Overview

Remove the song's `release_year` from the AI prompt in `RecordingMatcherTask`. The current implementation includes the (often incorrect) release_year, which causes the AI to filter out the original recordings we're trying to find.

**The Bug**: When enriching "Spanish Harlem" by Ben E. King with `release_year: 1987`, the prompt includes `Release year: 1987`, causing the AI to exclude the 1961 original recording.

**The Fix**: Remove one line of code - the existing system message works correctly once we stop telling the AI what year to match.

**Non-goals**:
- Changing the system message or user prompt structure
- Modifying any other part of the enrichment pipeline

## Context & Links

- Related specs:
  - `docs/specs/completed/release-year-correction.md` - Original implementation
- Source files (authoritative):
  - `app/lib/services/ai/tasks/music/songs/recording_matcher_task.rb:101` - Line to remove
- Tests:
  - `test/lib/services/ai/tasks/music/songs/recording_matcher_task_test.rb`

## Problem Analysis

In `recording_matcher_task.rb` line 101:
```ruby
parts << "Release year: #{parent.release_year}" if parent.release_year
```

This line adds the song's current (often incorrect) release_year to the AI prompt. The AI then uses this as a filter, excluding recordings from other years.

**Production example**:
```
SONG:
Title: "Spanish Harlem"
Artist(s): Ben E. King
Release year: 1987        <-- Causes AI to exclude 1961 original
```

## The Fix

Remove line 101 from `build_song_info`:

```ruby
def build_song_info
  artist_names = parent.artists.map(&:name).join(", ")
  parts = []
  parts << "Title: \"#{parent.title}\""
  parts << "Artist(s): #{artist_names}" if artist_names.present?
  # REMOVED: parts << "Release year: #{parent.release_year}" if parent.release_year
  parts.join("\n")
end
```

## Acceptance Criteria

- [x] `release_year` is NOT included in the AI prompt
- [x] Existing tests updated to not expect release_year in prompt
- [x] Tests verify release_year is NOT in prompt (using `refute_includes`)

### Golden Example

```text
Input:
  Song: "Spanish Harlem" by Ben E. King
  Current release_year: 1987 (incorrect)

AI Prompt (FIXED - no release_year):
  SONG:
  Title: "Spanish Harlem"
  Artist(s): Ben E. King

Result:
  - AI matches both 1961 and 1987 recordings
  - After update_release_year_from_identifiers!: release_year → 1961
```

---

## Agent Hand-Off

### Constraints
- One-line fix in `recording_matcher_task.rb`
- Update tests to match

### Required Outputs
- Updated `app/lib/services/ai/tasks/music/songs/recording_matcher_task.rb`
- Updated `test/lib/services/ai/tasks/music/songs/recording_matcher_task_test.rb`

### Key Files Touched (paths only)
- `app/lib/services/ai/tasks/music/songs/recording_matcher_task.rb`
- `test/lib/services/ai/tasks/music/songs/recording_matcher_task_test.rb`

---

## Implementation Notes (living)
- Removed line 101 that added `Release year: #{parent.release_year}` to the AI prompt
- Added comment explaining why release_year is intentionally omitted
- Updated two tests to verify release_year is NOT included (using `refute_includes`)

## Acceptance Results
- Date: 2026-01-27
- Tests: 17 runs, 78 assertions, 0 failures, 0 errors

## Documentation Updated
- [ ] `docs/services/ai/tasks/music/songs/recording_matcher_task.md`
