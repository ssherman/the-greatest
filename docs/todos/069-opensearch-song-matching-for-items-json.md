# [069] - OpenSearch Song Matching for items_json Enhancement

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-11-01
- **Started**:
- **Completed**:
- **Developer**:

## Overview
Enhance the song list items_json enrichment process by adding an OpenSearch-based matching step that finds songs in our local database before attempting MusicBrainz search. This will reduce duplicate songs by leveraging our existing OpenSearch index with title and artist matching, providing higher quality matches than MusicBrainz alone.

## Context

### Current Enrichment Flow Problems
The current enrichment flow (Task 064) has a critical limitation that leads to duplicate songs:

**Current Flow** (`Services::Lists::Music::Songs::ItemsJsonEnricher`):
1. Read song entry with `title` and `artists[]` from items_json
2. Join artists with `", "` separator
3. Search MusicBrainz API for recording matches
4. Take first MusicBrainz result
5. Check if song with that MusicBrainz ID exists locally
6. Add MusicBrainz metadata to items_json

**Problems**:
- **No local search first**: Never searches our own database before going to MusicBrainz
- **MusicBrainz can mismatch**: External API may return incorrect matches (live vs studio, covers, different recordings)
- **Creates duplicates**: If MusicBrainz returns a different recording MBID than the one we already have for the same song, we end up importing a duplicate
- **Ignores existing data**: We have indexed songs with normalized titles and artist names in OpenSearch that aren't checked

### Why OpenSearch Matching is Better

**Advantages of searching our own database first**:
1. **Deduplication**: Prevents importing songs we already have
2. **Higher quality data**: Our songs already went through import validation
3. **Existing relationships**: Songs already linked to artists and albums
4. **Faster**: No external API calls for songs we already have
5. **Better scoring**: Can tune relevance specifically for our data

### Where This Fits

This enhancement adds a new enrichment step BEFORE the existing MusicBrainz enrichment:

**New Flow**:
1. Read song entry with `title` and `artists[]` from items_json
2. **NEW**: Search OpenSearch for matching songs in our database
   - Search by title with high precision
   - Filter/boost by artist names (all artists in array)
   - Require high relevance score (e.g., min_score: 5.0)
   - Take highest scoring match
3. If OpenSearch match found with sufficient score:
   - Add `song_id` and `song_name` to items_json entry
   - **Skip MusicBrainz search** (we already have the song)
4. If no OpenSearch match or score too low:
   - Fall back to existing MusicBrainz enrichment flow
   - Continue with current process

### Related Work
- **Task 064**: Implemented `ItemsJsonEnricher` (MusicBrainz enrichment) - this will be enhanced
- **Task 065**: Implemented items_json viewer - will display OpenSearch match data
- **Task 066**: Implemented `ItemsJsonImporter` - already checks `song_id` field we'll populate
- **Existing**: `Search::Music::Search::SongGeneral` - pattern to follow for new search class
- **Existing**: `Search::Music::SongIndex` - song index with title and artist_names fields

## Requirements
- [ ] Create new OpenSearch search class that accepts separate title and artists parameters
- [ ] Search combines title matching (required, high boost) with artist matching (at least one should match)
- [ ] Return matches with relevance scores above configurable threshold
- [ ] Enhance `ItemsJsonEnricher` to search OpenSearch before MusicBrainz
- [ ] Populate `song_id` and `song_name` fields when OpenSearch match is found
- [ ] Skip MusicBrainz enrichment when local match is found
- [ ] Track statistics for OpenSearch matches vs MusicBrainz matches
- [ ] Write comprehensive tests for new search class
- [ ] Write tests for enhanced enricher logic
- [ ] Update enricher tests to verify OpenSearch-first flow

## Technical Approach

### 1. New OpenSearch Search Class

**Decision Point**: Create new class or extend existing `SongGeneral`?

**Option A: New Search Class** (RECOMMENDED)
- Create `Search::Music::Search::SongByTitleAndArtists`
- Accepts separate `title` (String) and `artists` (Array) parameters
- Uses `must` clause for title matching (required)
- Uses `should` clauses for artist matching (at least one must match)
- Higher default `min_score` (e.g., 5.0) for precision

**Option B: Extend SongGeneral with Optional Parameters**
- Add optional `title:` and `artists:` keyword arguments
- Keep backward compatibility with `call(text, options)`
- Conditional query building based on parameters
- More complex, harder to test

**Recommendation**: Option A - separate class is clearer and follows single responsibility principle.

### 2. Search Class Implementation

**Location**: `app/lib/search/music/search/song_by_title_and_artists.rb`

**Pattern Source**: Based on `SongGeneral` with modifications for structured parameters

**Class Structure**:
```ruby
module Search
  module Music
    module Search
      class SongByTitleAndArtists < ::Search::Base::Search
        def self.index_name
          ::Search::Music::SongIndex.index_name
        end

        def self.call(title:, artists:, options = {})
          # Validate inputs
          return empty_response if title.blank?
          return empty_response if artists.blank? || !artists.is_a?(Array)

          min_score = options[:min_score] || 5.0  # Higher default for precision
          size = options[:size] || 10
          from = options[:from] || 0

          query_definition = build_query_definition(title, artists, min_score, size, from)

          Rails.logger.info "Song title+artists search query: #{query_definition.inspect}"

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(title, artists, min_score, size, from)
          cleaned_title = ::Search::Shared::Utils.normalize_search_text(title)

          # Title matching (REQUIRED - use must clause)
          must_clauses = build_title_clauses(cleaned_title)

          # Artist matching (at least one should match)
          should_clauses = build_artist_clauses(artists)

          {
            min_score: min_score,
            size: size,
            from: from,
            query: ::Search::Shared::Utils.build_bool_query(
              must: [
                ::Search::Shared::Utils.build_bool_query(
                  should: must_clauses,
                  minimum_should_match: 1
                )
              ],
              should: should_clauses,
              minimum_should_match: 1
            )
          }
        end

        private

        def self.build_title_clauses(cleaned_title)
          [
            # Exact phrase match on title gets highest boost
            ::Search::Shared::Utils.build_match_phrase_query("title", cleaned_title, boost: 10.0),

            # Keyword exact match for precise title matches
            ::Search::Shared::Utils.build_term_query("title.keyword", cleaned_title.downcase, boost: 9.0),

            # Regular match on title with high boost (requires all words)
            ::Search::Shared::Utils.build_match_query("title", cleaned_title, boost: 8.0, operator: "and")
          ]
        end

        def self.build_artist_clauses(artists)
          clauses = []

          artists.each do |artist_name|
            next if artist_name.blank?

            cleaned_artist = ::Search::Shared::Utils.normalize_search_text(artist_name)

            # Artist phrase match
            clauses << ::Search::Shared::Utils.build_match_phrase_query("artist_names", cleaned_artist, boost: 6.0)

            # Artist match all words
            clauses << ::Search::Shared::Utils.build_match_query("artist_names", cleaned_artist, boost: 5.0, operator: "and")
          end

          clauses
        end

        def self.empty_response
          []
        end

        private_class_method :empty_response, :build_title_clauses, :build_artist_clauses
      end
    end
  end
end
```

**Key Implementation Details**:

1. **Required Title Matching**:
   - Title clauses wrapped in `must` array (at least one must match)
   - Three variations: phrase (10.0), keyword (9.0), match (8.0)
   - Uses same boost values as `SongGeneral` for consistency

2. **Artist Matching with OR Logic**:
   - Each artist in array gets two clauses: phrase (6.0) and match (5.0)
   - All artist clauses in `should` array with `minimum_should_match: 1`
   - This means "title must match AND at least one artist must match"
   - For multi-artist songs, increases chance of match if any artist matches

3. **Higher Default Min Score**:
   - Default `min_score: 5.0` vs `1.0` in `SongGeneral`
   - Requires higher relevance for precision (fewer false positives)
   - Can be overridden via options for flexibility

4. **Validation**:
   - Returns empty response if title blank
   - Returns empty response if artists not array or empty
   - Skips blank artist names in loop

### 3. Enhanced ItemsJsonEnricher

**Location**: `app/lib/services/lists/music/songs/items_json_enricher.rb`

**Changes to `enrich_song_entry` method**:

```ruby
def enrich_song_entry(song_entry)
  title = song_entry["title"]
  artists = song_entry["artists"]

  # STEP 1: Try OpenSearch match first (NEW)
  opensearch_match = find_local_song(title, artists)

  if opensearch_match
    Rails.logger.info "Found local song via OpenSearch: #{opensearch_match[:song].title} (ID: #{opensearch_match[:song].id}, score: #{opensearch_match[:score]})"

    enrichment_data = {
      "song_id" => opensearch_match[:song].id,
      "song_name" => opensearch_match[:song].title,
      "opensearch_match" => true,
      "opensearch_score" => opensearch_match[:score]
    }

    return {success: true, data: enrichment_data, source: :opensearch}
  end

  # STEP 2: Fall back to MusicBrainz if no local match (EXISTING FLOW)
  Rails.logger.info "No local song found via OpenSearch, trying MusicBrainz for: #{title} by #{artists.join(", ")}"

  artist_name = artists.join(", ")
  search_result = search_service.search_by_artist_and_title(artist_name, title)

  unless search_result[:success] && search_result[:data]["recordings"]&.any?
    return {success: false, error: "No MusicBrainz match found"}
  end

  recording = search_result[:data]["recordings"].first
  mb_recording_id = recording["id"]
  mb_recording_name = recording["title"]

  artist_credits = recording["artist-credit"] || []
  mb_artist_ids = artist_credits.map { |credit| credit.dig("artist", "id") }.compact
  mb_artist_names = artist_credits.map { |credit| credit.dig("artist", "name") }.compact

  existing_song = ::Music::Song.with_identifier(:music_musicbrainz_recording_id, mb_recording_id).first
  song_id = existing_song&.id
  song_name = existing_song&.title

  enrichment_data = {
    "mb_recording_id" => mb_recording_id,
    "mb_recording_name" => mb_recording_name,
    "mb_artist_ids" => mb_artist_ids,
    "mb_artist_names" => mb_artist_names,
    "musicbrainz_match" => true
  }

  if song_id
    enrichment_data["song_id"] = song_id
    enrichment_data["song_name"] = song_name
  end

  {success: true, data: enrichment_data, source: :musicbrainz}
rescue => e
  {success: false, error: e.message}
end

private

def find_local_song(title, artists)
  return nil if title.blank? || artists.blank?

  search_results = ::Search::Music::Search::SongByTitleAndArtists.call(
    title: title,
    artists: artists,
    size: 1,
    min_score: 5.0  # Require high relevance for confidence
  )

  return nil if search_results.empty?

  result = search_results.first
  song_id = result[:id].to_i
  score = result[:score]

  song = ::Music::Song.find_by(id: song_id)

  return nil unless song

  {song: song, score: score}
rescue => e
  Rails.logger.error "Error searching OpenSearch for local song: #{e.message}"
  nil
end
```

**Key Implementation Details**:

1. **Search Order**:
   - Try OpenSearch first (NEW)
   - Fall back to MusicBrainz if no match (EXISTING)
   - Preserves existing behavior as fallback

2. **OpenSearch Match Criteria**:
   - Must have results
   - Must meet min_score threshold (5.0)
   - Song must exist in database (by ID)
   - Returns nil on any error (falls back to MusicBrainz)

3. **Enrichment Data Fields**:
   - OpenSearch match: `song_id`, `song_name`, `opensearch_match: true`, `opensearch_score`
   - MusicBrainz match: existing fields plus `musicbrainz_match: true`
   - Source tracking: return `:opensearch` or `:musicbrainz` in result

4. **Statistics Tracking**:
   - Enhance `call` method to track OpenSearch vs MusicBrainz counts
   - Add to result hash: `opensearch_matches`, `musicbrainz_matches`

### 4. Enhanced Statistics in ItemsJsonEnricher

**Changes to `call` method**:

```ruby
def call
  validate_list!

  enriched_count = 0
  skipped_count = 0
  opensearch_matches = 0  # NEW
  musicbrainz_matches = 0  # NEW

  songs_data = @list.items_json["songs"]

  enriched_songs = songs_data.map do |song_entry|
    enrichment = enrich_song_entry(song_entry)

    if enrichment[:success]
      enriched_count += 1

      # Track source (NEW)
      if enrichment[:source] == :opensearch
        opensearch_matches += 1
      elsif enrichment[:source] == :musicbrainz
        musicbrainz_matches += 1
      end

      song_entry.merge(enrichment[:data])
    else
      skipped_count += 1
      Rails.logger.warn "Skipped enrichment for #{song_entry["title"]} by #{song_entry["artists"].join(", ")}: #{enrichment[:error]}"
      song_entry
    end
  end

  @list.update!(items_json: {"songs" => enriched_songs})

  success_result(enriched_count, skipped_count, songs_data.length, opensearch_matches, musicbrainz_matches)
rescue ArgumentError
  raise
rescue => e
  Rails.logger.error "ItemsJsonEnricher failed: #{e.message}"
  failure_result(e.message)
end

private

def success_result(enriched_count, skipped_count, total_count, opensearch_matches, musicbrainz_matches)
  {
    success: true,
    message: "Enriched #{enriched_count} of #{total_count} songs (#{opensearch_matches} from OpenSearch, #{musicbrainz_matches} from MusicBrainz, #{skipped_count} skipped)",
    enriched_count: enriched_count,
    skipped_count: skipped_count,
    total_count: total_count,
    opensearch_matches: opensearch_matches,
    musicbrainz_matches: musicbrainz_matches
  }
end
```

### 5. Test Strategy

**New Test File**: `test/lib/search/music/search/song_by_title_and_artists_test.rb`

**Test Coverage**:
1. Configuration (index_name delegates to SongIndex)
2. Validates title is required (blank title returns empty)
3. Validates artists is required (blank/nil/non-array returns empty)
4. Searches with single artist and returns matches
5. Searches with multiple artists (should match if any artist matches)
6. Returns empty for no matches
7. Respects min_score threshold (filters low scores)
8. Uses higher default min_score (5.0 vs 1.0)
9. Supports custom options (size, from, min_score)
10. Returns results with id, score, source structure
11. Title must match (even if artist matches perfectly)
12. At least one artist must match (even if title matches perfectly)

**Enhanced Enricher Tests**: Modify `test/lib/services/lists/music/songs/items_json_enricher_test.rb`

**New Test Cases**:
1. OpenSearch match found (high score):
   - Calls OpenSearch search
   - Returns song_id and song_name
   - Does NOT call MusicBrainz
   - Tracks source as :opensearch
   - Increments opensearch_matches count

2. OpenSearch match too low score:
   - Calls OpenSearch search
   - Gets result but score < 5.0
   - Falls back to MusicBrainz
   - Tracks source as :musicbrainz

3. OpenSearch returns no results:
   - Calls OpenSearch search
   - Gets empty results
   - Falls back to MusicBrainz
   - Tracks source as :musicbrainz

4. OpenSearch error:
   - OpenSearch raises exception
   - Logs error
   - Falls back to MusicBrainz
   - Enrichment succeeds via fallback

5. Multi-artist song:
   - Passes array with multiple artists
   - OpenSearch should clauses include all artists
   - Match succeeds if any artist matches

6. Statistics tracking:
   - Some songs matched via OpenSearch
   - Some songs matched via MusicBrainz
   - Result includes correct counts for both sources

## Dependencies
- **Existing**: `Search::Music::SongIndex` - song index with title and artist_names fields
- **Existing**: `Search::Base::Search` - base search class
- **Existing**: `Search::Shared::Utils` - query building utilities
- **Existing**: `Services::Lists::Music::Songs::ItemsJsonEnricher` - will be enhanced
- **Existing**: `Music::Song` model with indexed data
- **Existing**: OpenSearch infrastructure and indexing

## Acceptance Criteria
- [ ] New search class accepts title (String) and artists (Array) parameters
- [ ] Search requires title to match (must clause) with high boost
- [ ] Search requires at least one artist to match (should clause with minimum_should_match: 1)
- [ ] Default min_score is 5.0 (higher than general search)
- [ ] Returns empty response for blank title or blank/invalid artists
- [ ] Enricher searches OpenSearch BEFORE MusicBrainz
- [ ] Enricher populates song_id and song_name when OpenSearch match found
- [ ] Enricher skips MusicBrainz when OpenSearch match is sufficient
- [ ] Enricher falls back to MusicBrainz when no OpenSearch match
- [ ] Enricher handles OpenSearch errors gracefully (falls back to MusicBrainz)
- [ ] Statistics track OpenSearch matches vs MusicBrainz matches separately
- [ ] Result message includes counts from both sources
- [ ] All tests pass with 100% coverage for new code
- [ ] Multi-artist songs can match on any artist in array

## Design Decisions

### 1. New Search Class vs Extending SongGeneral
**Decision**: Create new `SongByTitleAndArtists` class instead of extending `SongGeneral`.

**Rationale**:
- **Single Responsibility**: Each search class has one clear purpose
- **Clear Interface**: Separate parameters (title:, artists:) vs free text
- **Different Query Logic**: Must/should structure vs all should clauses
- **Different Defaults**: Higher min_score (5.0) for precision vs general search (1.0)
- **Easier Testing**: Test one search strategy without conditional logic
- **Consistent Pattern**: All existing search classes are focused (not multi-purpose)

**Trade-off**: Slight code duplication in boost values and query building, but clearer separation of concerns.

### 2. Must Clause for Title, Should for Artists
**Decision**: Wrap title clauses in `must` array, artist clauses in `should` array with `minimum_should_match: 1`.

**Rationale**:
- **Title is Required**: Can't match a song without knowing the title
- **Artist is Filtering**: At least one artist must match for confidence
- **Handles Multi-Artist**: If song has multiple artists, any match is good
- **Better Precision**: Reduces false positives from artist-only matches
- **MusicBrainz Analogy**: Similar to MusicBrainz search with `title AND artist` query

**Alternative Considered**: Put everything in should clauses - rejected because allows artist-only matches with no title match.

### 3. Higher Default Min Score (5.0)
**Decision**: Use `min_score: 5.0` by default instead of `1.0`.

**Rationale**:
- **Precision Over Recall**: Better to miss a match than create incorrect duplicate
- **Fallback Available**: MusicBrainz will catch anything we miss
- **Boost Values**: With boosts of 10.0, 9.0, 8.0, 6.0, 5.0, a score of 5.0 requires at least one high-quality match
- **Existing Data Quality**: Our indexed songs are already vetted, so high scores indicate genuine matches
- **Configurable**: Can be lowered via options if needed for specific use cases

**Trade-off**: May miss some valid matches, but prevents incorrect enrichment which is worse.

### 4. Search OpenSearch First, MusicBrainz Second
**Decision**: Try OpenSearch match before MusicBrainz search.

**Rationale**:
- **Deduplication Goal**: Primary objective is finding existing songs to avoid duplicates
- **Speed**: Local search is faster than external API
- **Data Quality**: Our data is already validated and linked
- **Graceful Degradation**: MusicBrainz fallback ensures no functionality loss
- **Resource Efficiency**: Reduces external API calls

**Alternative Considered**: Run both and compare - rejected as too complex and defeats efficiency goal.

### 5. Add opensearch_match Field to items_json
**Decision**: Add `opensearch_match: true` and `opensearch_score` fields to enriched entries.

**Rationale**:
- **Transparency**: Admin can see which source matched
- **Debugging**: Easier to understand enrichment results
- **Validation**: Can review low-scoring matches in viewer
- **Consistency**: Similar to how we track AI validation with `ai_match_invalid`

**Trade-off**: Adds fields to items_json, but they're informative and don't affect import logic.

### 6. Return Empty on Validation Failure
**Decision**: Return empty array if title or artists are invalid.

**Rationale**:
- **Fail Fast**: Invalid input should not execute query
- **Consistent Pattern**: Matches `SongGeneral.call` behavior
- **Caller Responsibility**: Enricher should validate before calling
- **No Exceptions**: Empty response is easier to handle than raising errors

**Pattern**: Same as all other OpenSearch search classes in codebase.

### 7. Track Source in Enrichment Result
**Decision**: Return `:opensearch` or `:musicbrainz` in enrichment result hash.

**Rationale**:
- **Statistics Tracking**: Need to count matches by source
- **Debugging**: Easier to trace enrichment flow
- **Testing**: Can verify correct fallback behavior
- **Logging**: Can include source in log messages

**Alternative Considered**: Track only in items_json fields - rejected because statistics need runtime counts.

### 8. Minimum Score Configurable but Opinionated Default
**Decision**: Default to 5.0 but allow override via `min_score:` option.

**Rationale**:
- **Opinionated Default**: High precision by default (fewer errors)
- **Flexibility**: Can experiment with threshold without code changes
- **Testing**: Can use lower threshold in tests for reliability
- **Future Tuning**: Can adjust based on real-world match quality

**Pattern**: Same as other search classes with `min_score` option.

### 9. No Caching of Search Results
**Decision**: Call OpenSearch on every enrichment, no caching.

**Rationale**:
- **Correctness**: Index may change between enrichments
- **Simplicity**: No cache invalidation logic needed
- **Performance**: OpenSearch is fast enough for this use case
- **Rare Operation**: Enrichment runs once per list, not repeatedly

**Alternative Considered**: Cache search results during single enrichment run - rejected as premature optimization.

### 10. Build Artist Clauses Per Artist (Not Combined)
**Decision**: Create separate phrase and match clauses for each artist in array.

**Rationale**:
- **Better Matching**: "Jay-Z" should match even if "Alicia Keys" doesn't
- **Multi-Artist Songs**: Increases chance of match with accurate artist
- **Boost Preservation**: Each artist gets same boost values
- **OpenSearch Optimization**: OpenSearch efficiently handles multiple should clauses

**Alternative Considered**: Join artists into single string - rejected because reduces match flexibility.

## Field Mapping: Items JSON Structure

### Before OpenSearch Enhancement
```json
{
  "rank": 1,
  "title": "Come Together",
  "artists": ["The Beatles"],
  "release_year": 1969
}
```

### After OpenSearch Match (New)
```json
{
  "rank": 1,
  "title": "Come Together",
  "artists": ["The Beatles"],
  "release_year": 1969,
  "song_id": 123,
  "song_name": "Come Together",
  "opensearch_match": true,
  "opensearch_score": 24.5
}
```

### After MusicBrainz Match (Existing)
```json
{
  "rank": 1,
  "title": "Come Together",
  "artists": ["The Beatles"],
  "release_year": 1969,
  "mb_recording_id": "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
  "mb_recording_name": "Come Together",
  "mb_artist_ids": ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"],
  "mb_artist_names": ["The Beatles"],
  "song_id": 123,
  "song_name": "Come Together",
  "musicbrainz_match": true
}
```

**Note**: Both enrichment paths populate `song_id` and `song_name` when song exists locally. The difference is OpenSearch finds it directly while MusicBrainz finds it via MBID lookup.

## Performance Considerations

### OpenSearch Query Complexity
- **Must + Should Query**: More complex than simple should query
- **Multiple Clauses**: 3 title + (2 × number of artists) clauses
- **Expected Performance**: Still sub-100ms for typical queries
- **Index Usage**: Uses existing song index (no new index needed)

### Enrichment Performance Impact
- **Additional Search**: Adds one OpenSearch query per song entry
- **Typical List**: 50-100 songs = 50-100 OpenSearch queries
- **Expected Time**: ~5-10 seconds for typical list (vs ~30-60s for MusicBrainz)
- **Cache Benefit**: OpenSearch results are fast (in-memory)
- **Network Benefit**: No external API calls for matched songs

### Optimization Opportunities
- **Batch Searching**: Could search multiple songs in single OpenSearch query
- **Parallel Processing**: Could search songs in parallel (if needed)
- **Score Tuning**: Could adjust boost values based on match quality data

**Current Approach**: Sequential per-song search is sufficient for now, can optimize later if needed.

## Future Enhancements

### Phase 2: Confidence Scoring
- Add confidence level to matches (high/medium/low) based on score ranges
- Show confidence in items_json viewer
- Allow manual override for medium confidence matches

### Phase 3: Batch Search
- Search multiple songs in single OpenSearch query
- Use bool should query with nested must clauses
- Improves performance for large lists (100+ songs)

### Phase 4: Machine Learning Match Validation
- Train model on confirmed matches vs false positives
- Use features: score, title similarity, artist overlap, release year proximity
- Auto-flag low-confidence matches for review

### Phase 5: Interactive Match Review
- Admin UI for reviewing OpenSearch vs MusicBrainz matches
- Side-by-side comparison of match data
- Manual selection of correct match
- Feedback loop for score threshold tuning

## Related Tasks

- **Prerequisite**: [064 - Enrich Song List items_json with MusicBrainz Data](064-import-song-list-from-musicbrainz-non-series.md) - Existing enrichment flow
- **Related**: [065 - Items JSON Viewer and AI Validation for Song Lists](065-items-json-viewer-songs.md) - Viewer will display OpenSearch match data
- **Related**: [066 - Import Songs and Create list_items from items_json](066-import-songs-from-items-json.md) - Already uses song_id field we'll populate
- **Related**: [068 - Song Duplicate Finder and Auto-Merge Rake Tasks](068-song-duplicate-finder-rake-tasks.md) - Addresses duplicate songs problem this task prevents
- **Pattern**: SongGeneral search class - Pattern to follow for new search

## Implementation Notes

*[This section will be filled out during/after implementation]*

### Approach Taken
*To be documented*

### Key Files Changed
*To be documented*

### Challenges Encountered
*To be documented*

### Deviations from Plan
*To be documented*

### Code Examples
*To be documented*

### Testing Approach
*To be documented*

### Performance Considerations
*To be documented*

### Future Improvements
*To be documented*

### Lessons Learned
*To be documented*

### Related PRs
*To be documented*

### Documentation Updated
- [ ] This task file updated with implementation notes
- [ ] Class documentation created: `docs/lib/search/music/search/song_by_title_and_artists.md`
- [ ] Class documentation updated: `docs/lib/services/lists/music/songs/items_json_enricher.md`
- [ ] Main todo.md updated with task status
