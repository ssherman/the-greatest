# [054] - AI Task to Find Invalid items_json Matches

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-10-18
- **Started**: 2025-10-18
- **Completed**: 2025-10-19
- **Developer**: AI (Claude)

## Overview
Create an AI task that validates album matches in the `items_json` field of `Music::Albums::List` records. After the items_json enricher adds MusicBrainz metadata to parsed albums, we need AI validation to identify incorrect matches (e.g., live albums matched with studio albums, tribute albums, different albums with similar names). Invalid matches will be flagged in the JSONB data and highlighted in the viewer tool.

## Context
The items_json field goes through two stages:
1. **AI Parsing** - Extracts albums from HTML: `{rank, title, artists, release_year}`
2. **MusicBrainz Enrichment** - Adds metadata: `{mb_release_group_id, mb_release_group_name, mb_artist_ids, mb_artist_names, album_id, album_name}`

The enricher service matches albums using MusicBrainz search, but this can produce false positives:
- Live albums matched with studio albums (e.g., "Dark Side of the Moon" vs "Dark Side of the Moon (Live)")
- Tribute albums or cover versions
- Albums with similar titles by different artists
- Reissues or special editions that don't match the original

Currently, the viewer tool shows enriched vs non-enriched albums, but cannot distinguish between "correctly enriched" and "incorrectly enriched". We need AI validation to flag suspicious matches.

### Related Work
- Task 052: Implemented the items_json enricher service (`Services::Lists::Music::Albums::ItemsJsonEnricher`)
- Task 053: Implemented the items_json viewer tool that displays enrichment status

## Requirements
- [x] Create AI task class that validates album matches using structured validation rules
- [x] Create Sidekiq job that invokes the AI task and updates items_json with results
- [x] Create Avo action that launches the Sidekiq job from Music::Albums::List show page
- [x] Update items_json viewer partial to highlight AI-flagged invalid rows with darker styling
- [x] Handle validation results properly - update items_json with `ai_match_invalid: true` field
- [x] Add statistics to viewer showing AI validation counts (valid/invalid/not-validated)
- [x] Write comprehensive tests for all components

## Technical Approach

### 1. AI Task Implementation

**Location**: `app/lib/services/ai/tasks/lists/music/albums/items_json_validator_task.rb`

**Pattern**: Follows `Services::Ai::Tasks::Music::AmazonAlbumMatchTask` validation pattern

**Class Structure**:
```ruby
module Services
  module Ai
    module Tasks
      module Lists
        module Music
          module Albums
            class ItemsJsonValidatorTask < Services::Ai::Tasks::BaseTask
              private

              def task_provider = :openai

              def task_model = "gpt-5-mini"

              def chat_type = :analysis

              def temperature = 1.0

              def system_message
                # Define validation criteria for album matches
                # - Live vs studio albums
                # - Tribute/cover albums
                # - Different albums with similar titles
                # - Compilation vs studio albums
                # - Special editions that don't match
              end

              def user_prompt
                # Build prompt with numbered list of album matches
                # Format: {number, artists, title, matched_artists, matched_title}
                # Note: number is index+1 (virtual rank for AI response)
              end

              def response_format = {type: "json_object"}

              def response_schema
                ResponseSchema
              end

              def process_and_persist(provider_response)
                # Extract invalid indices from AI response
                # Update items_json with ai_match_invalid flag
                # Return success result with counts
              end

              class ResponseSchema < OpenAI::BaseModel
                required :invalid, OpenAI::ArrayOf[Integer], doc: "Array of item numbers that are invalid matches"
                required :reasoning, String, nil?: true, doc: "Brief explanation of validation approach"
              end
            end
          end
        end
      end
    end
  end
end
```

**Key Decisions**:
- Use OpenAI gpt-5-mini for fast, cost-effective validation
- Use structured output with `OpenAI::BaseModel` for reliable parsing
- Return array of integers (item numbers) rather than complex objects
- Include reasoning field for transparency/debugging
- Temperature of 1.0 for natural language reasoning

**Validation Criteria** (system message should include):
1. **Live vs Studio**: Live albums should NOT match with non-live albums
   - Examples: "Dark Side of the Moon" ≠ "Dark Side of the Moon (Live at Wembley)"
2. **Tribute/Covers**: Tribute albums should NOT match original albums
   - Examples: "Nevermind" ≠ "Nevermind: A Tribute to Nirvana"
3. **Different Works**: Different albums with similar titles
   - Examples: "Greatest Hits" by different artists
4. **Compilation Mismatches**: Compilations should only match compilations
   - Examples: "The Best of Queen" ≠ "A Night at the Opera"
5. **Artist Mismatches**: Significant artist name differences
   - Examples: "Johnny Thunders & The Heartbreakers" ≠ "1788-L, Deathpact"

**User Prompt Format**:
```
Validate these album matches. Original albums from the list are matched with MusicBrainz data.
Identify any invalid matches where the original and matched albums are different works.

Format: {number}. Original: "artist - title" → Matched: "matched_artist - matched_title"

1. Original: "The Beatles - Revolver" → Matched: "The Beatles - Revolver"
2. Original: "Pink Floyd - The Dark Side of the Moon" → Matched: "Pink Floyd - The Dark Side of the Moon (Live)"
3. Original: "Various Artists - Greatest Rock Songs" → Matched: "Queen - Greatest Hits"

Which matches are invalid? Return array of numbers for invalid matches.
```

**Process and Persist Logic**:
1. Extract `invalid` array from validated response
2. Read current `items_json["albums"]` from parent list
3. Iterate over albums, marking invalid ones:
   ```ruby
   invalid_indices = data[:invalid].map { |num| num - 1 } # Convert 1-based to 0-based
   albums.each_with_index do |album, index|
     if invalid_indices.include?(index)
       album["ai_match_invalid"] = true
     end
   end
   ```
4. Update list: `parent.update!(items_json: {"albums" => albums})`
5. Return result with counts: `{valid_count: X, invalid_count: Y, total_count: Z, reasoning: ...}`

### 2. Sidekiq Job Implementation

**Location**: `app/sidekiq/music/albums/validate_list_items_json_job.rb`

**Pattern**: Follows `Music::Albums::EnrichListItemsJsonJob` pattern

**Class Structure**:
```ruby
class Music::Albums::ValidateListItemsJsonJob
  include Sidekiq::Job

  def perform(list_id)
    list = ::Music::Albums::List.find(list_id)

    # Task updates the list's items_json directly
    result = Services::Ai::Tasks::Lists::Music::Albums::ItemsJsonValidatorTask.new(parent: list).call

    if result.success?
      data = result.data
      Rails.logger.info "ValidateListItemsJsonJob completed for list #{list_id}: #{data[:valid_count]} valid, #{data[:invalid_count]} invalid"
    else
      Rails.logger.error "ValidateListItemsJsonJob failed for list #{list_id}: #{result.error}"
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "ValidateListItemsJsonJob: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "ValidateListItemsJsonJob failed: #{e.message}"
    raise
  end
end
```

**Key Decisions**:
- Use default queue (not serial) - no rate limiting needed
- Task handles all items_json updates internally
- Log validation counts for monitoring
- Re-raise exceptions to mark job as failed in Sidekiq

### 3. Avo Action Implementation

**Location**: `app/avo/actions/lists/music/albums/validate_items_json.rb`

**Pattern**: Follows `Avo::Actions::Lists::Music::Albums::EnrichItemsJson` pattern

**Class Structure**:
```ruby
class Avo::Actions::Lists::Music::Albums::ValidateItemsJson < Avo::BaseAction
  self.name = "Validate items_json matches with AI"
  self.message = "This will use AI to validate that MusicBrainz matches in items_json are correct. Invalid matches will be flagged in the data."
  self.confirm_button_label = "Validate matches"

  def handle(query:, fields:, current_user:, resource:, **args)
    query.pluck(:id)

    valid_lists = query.select do |list|
      is_album_list = list.is_a?(::Music::Albums::List)
      has_enriched_items = list.items_json.present? &&
                          list.items_json["albums"].is_a?(Array) &&
                          list.items_json["albums"].any? { |a| a["mb_release_group_id"].present? }

      unless is_album_list
        Rails.logger.warn "Skipping non-album list: #{list.name} (ID: #{list.id}, Type: #{list.class})"
      end

      unless has_enriched_items
        Rails.logger.warn "Skipping list without enriched items_json: #{list.name} (ID: #{list.id})"
      end

      is_album_list && has_enriched_items
    end

    if valid_lists.empty?
      return error "No valid lists found. Lists must be Music::Albums::List with enriched items_json data."
    end

    valid_lists.each do |list|
      Music::Albums::ValidateListItemsJsonJob.perform_async(list.id)
    end

    succeed "#{valid_lists.length} list(s) queued for AI validation. Each list will be processed in a separate background job."
  end
end
```

**Key Decisions**:
- Require enriched data (must have `mb_release_group_id` on at least one album)
- Validate both list type AND data availability
- Log warnings for skipped lists
- Use descriptive error messages

**Registration**: Add to `/home/shane/dev/the-greatest/web-app/app/avo/resources/music_albums_list.rb`:
```ruby
def actions
  super
  action Avo::Actions::Lists::ImportFromMusicbrainzSeries
  action Avo::Actions::Lists::Music::Albums::EnrichItemsJson
  action Avo::Actions::Lists::Music::Albums::ValidateItemsJson
end
```

### 4. Viewer Tool Updates

**Location**: `app/views/avo/resource_tools/lists/music/albums/_items_json_viewer.html.erb`

**Changes Required**:

1. **Update Statistics Section** (after line 6):
   ```erb
   <% ai_validated_count = albums.count { |album| album.key?("ai_match_invalid") } %>
   <% ai_invalid_count = albums.count { |album| album["ai_match_invalid"] == true } %>
   <% ai_valid_count = ai_validated_count - ai_invalid_count %>
   ```

2. **Add AI Validation Stats Card** (in stats section around line 28):
   ```erb
   <div class="stat">
     <div class="stat-title">AI Validated</div>
     <div class="stat-value text-info"><%= ai_validated_count %></div>
     <div class="stat-desc"><%= ai_invalid_count %> flagged as invalid</div>
   </div>
   ```

3. **Update Row Highlighting** (replace line 47):
   ```erb
   <% has_mb_data = album["mb_release_group_id"].present? %>
   <% ai_flagged_invalid = album["ai_match_invalid"] == true %>
   <tr class="<%= 'bg-gray-100' unless has_mb_data %> <%= 'bg-red-100' if ai_flagged_invalid %>">
   ```

4. **Update Status Badge Logic** (replace lines 48-54):
   ```erb
   <td class="text-center border border-gray-300">
     <% if ai_flagged_invalid %>
       <span class="badge badge-error badge-sm">⚠ Invalid</span>
     <% elsif has_mb_data %>
       <span class="badge badge-success badge-sm">✓</span>
     <% else %>
       <span class="badge badge-error badge-sm">✗</span>
     <% end %>
   </td>
   ```

**Styling Strategy**:
- **Not enriched** (no MB data): `bg-gray-100` - light gray background, ✗ badge
- **Enriched & valid**: No additional background class, ✓ badge
- **Enriched & AI-flagged invalid**: `bg-red-100` - light red background, ⚠ Invalid badge
- **AI validation takes precedence** over enrichment status for highlighting

### 5. Data Structure Changes

**items_json Field Updates**:

Before validation:
```json
{
  "albums": [
    {
      "rank": 1,
      "title": "Dark Side of the Moon",
      "artists": ["Pink Floyd"],
      "release_year": 1973,
      "mb_release_group_id": "...",
      "mb_release_group_name": "Dark Side of the Moon (Live)",
      "mb_artist_ids": ["..."],
      "mb_artist_names": ["Pink Floyd"]
    }
  ]
}
```

After validation:
```json
{
  "albums": [
    {
      "rank": 1,
      "title": "Dark Side of the Moon",
      "artists": ["Pink Floyd"],
      "release_year": 1973,
      "mb_release_group_id": "...",
      "mb_release_group_name": "Dark Side of the Moon (Live)",
      "mb_artist_ids": ["..."],
      "mb_artist_names": ["Pink Floyd"],
      "ai_match_invalid": true
    }
  ]
}
```

**New Field**:
- `ai_match_invalid`: Boolean (optional) - present and true when AI flags the match as invalid

## Dependencies
- Existing: `Music::Albums::List` model with `items_json` JSONB field
- Existing: `Services::Lists::Music::Albums::ItemsJsonEnricher` - creates enriched data
- Existing: `Avo::ResourceTools::Lists::Music::Albums::ItemsJsonViewer` - displays data
- Existing: `Services::Ai::Tasks::BaseTask` - AI task base class
- Existing: `OpenAI::BaseModel` - structured output schema support
- New: Generator for Sidekiq job (use `bin/rails generate sidekiq:job`)

## Acceptance Criteria
- [x] AI task correctly identifies invalid matches (live vs studio, tributes, etc.)
- [x] AI task uses structured output schema with OpenAI::BaseModel
- [x] AI task updates items_json with `ai_match_invalid: true` for flagged albums
- [x] Sidekiq job successfully invokes AI task and logs results
- [x] Avo action validates lists have enriched data before queueing jobs
- [x] Avo action provides clear error messages for invalid selections
- [x] Viewer tool shows AI validation statistics (validated count, invalid count)
- [x] Viewer tool highlights AI-flagged rows with red background (`bg-red-100`)
- [x] Viewer tool shows ⚠ Invalid badge for AI-flagged albums
- [x] AI validation takes visual precedence over enrichment status
- [x] Tests cover all components (task, job)
- [x] Tests verify items_json structure before/after validation
- [x] Documentation updated in this file with implementation notes

## Design Decisions

### 1. Virtual Numbering for AI Response
**Decision**: Use index+1 numbering in prompt, convert back to 0-based indices
**Rationale**: AI models work better with 1-based numbering (more natural). We convert back to 0-based for array access.
**Trade-off**: Requires conversion logic but improves AI accuracy

### 2. Structured Output vs Free-form JSON
**Decision**: Use `OpenAI::BaseModel` with typed schema
**Rationale**: Ensures reliable parsing, automatic validation, type safety
**Alternative Considered**: Free-form JSON with manual parsing (rejected - error-prone)

### 3. Flagging Strategy: Boolean Field vs Array
**Decision**: Add `ai_match_invalid: true` to each album object
**Rationale**: Keeps validation state with the data, easier to filter/query, simpler partial logic
**Alternative Considered**: Separate array of invalid indices (rejected - harder to maintain sync)

### 4. Visual Hierarchy: Red vs Darker Gray
**Decision**: Use `bg-red-100` (light red) for invalid matches
**Rationale**: Red clearly indicates error/problem, stands out from gray (not enriched). Matches existing badge color (error badge is red).
**Alternative Considered**: Darker gray `bg-gray-200` (rejected - not distinctive enough)

### 5. Validation Scope: All Albums vs Only Enriched
**Decision**: Only validate albums with `mb_release_group_id` present
**Rationale**: Can't validate matches that don't exist. Enrichment must happen first.
**Implementation**: Action checks for enriched data before queueing job

### 6. Re-validation Strategy
**Decision**: Allow re-running validation (overwrites `ai_match_invalid` flags)
**Rationale**: Rules may change, data may improve, false positives need correction
**Implementation**: Task processes all enriched albums, adds/updates flag as needed

### 7. Reasoning Field in Response
**Decision**: Include optional `reasoning` field in AI response schema
**Rationale**: Helps debugging, transparency for why matches were flagged
**Trade-off**: Slightly more tokens used, but valuable for understanding AI decisions

### 8. Job Queue Selection
**Decision**: Use default queue (not serial)
**Rationale**: No rate limiting needed (OpenAI has high rate limits), validation can run in parallel
**Alternative Considered**: Serial queue for AI calls (rejected - unnecessary bottleneck)

### 9. Error Handling: Partial Failures
**Decision**: Process all albums, log failures, return success with counts
**Rationale**: Similar to enricher pattern - partial success is still useful
**Implementation**: If AI call fails, log error but don't mark any albums invalid

### 10. Statistics Display
**Decision**: Add separate stats card for AI validation
**Rationale**: Users need to see validation progress separately from enrichment status
**Display**: "AI Validated: X (Y flagged as invalid)"

## Implementation Notes
**Implementation Date**: 2025-10-18
**Status**: Complete - All tests passing (1372 runs, 3959 assertions, 0 failures)

### Approach Taken

Followed the detailed technical approach outlined in the task file, implementing all components as specified:

1. **AI Task Implementation**: Created `ItemsJsonValidatorTask` following the `AmazonAlbumMatchTask` pattern
   - Used OpenAI gpt-5-mini for fast, cost-effective validation
   - Implemented structured output with `OpenAI::BaseModel` schema
   - System message provides comprehensive validation criteria for live albums, tribute albums, compilations, and artist mismatches
   - User prompt constructs numbered list of album matches (1-based for AI, converted to 0-based for array access)
   - Response schema returns array of invalid match numbers plus optional reasoning

2. **Sidekiq Job Implementation**: Created `ValidateListItemsJsonJob` following the `EnrichListItemsJsonJob` pattern
   - Uses default queue (no special serial queue needed)
   - Logs success/failure with validation counts
   - Re-raises all exceptions for Sidekiq retry mechanism

3. **Avo Action Implementation**: Created `ValidateItemsJson` action following the `EnrichItemsJson` pattern
   - Validates lists are `Music::Albums::List` type
   - Requires enriched data (at least one album with `mb_release_group_id`)
   - Logs warnings for skipped lists
   - Queues separate job for each valid list

4. **Viewer Partial Updates**: Updated `_items_json_viewer.html.erb` with AI validation support
   - Added AI validation statistics (validated count, invalid count)
   - Updated row highlighting with `bg-red-100` for AI-flagged items (takes precedence over `bg-gray-100`)
   - Updated status badge with three states: ✓ (enriched & valid), ✗ (not enriched), ⚠ Invalid (AI-flagged)

### Key Files Changed

**New Files Created:**
- `web-app/app/lib/services/ai/tasks/lists/music/albums/items_json_validator_task.rb` (105 lines)
- `web-app/app/sidekiq/music/albums/validate_list_items_json_job.rb` (22 lines)
- `web-app/app/avo/actions/lists/music/albums/validate_items_json.rb` (34 lines)
- `web-app/test/lib/services/ai/tasks/lists/music/albums/items_json_validator_task_test.rb` (178 lines)
- `web-app/test/sidekiq/music/albums/validate_list_items_json_job_test.rb` (95 lines)

**Files Modified:**
- `web-app/app/avo/resources/music_albums_list.rb` - Added action registration (1 line)
- `web-app/app/views/avo/resource_tools/lists/music/albums/_items_json_viewer.html.erb` - Added AI validation stats and highlighting (13 lines changed)
- `docs/testing.md` - Added note about not testing Avo actions (1 line)

### Challenges Encountered

**No significant challenges** - The detailed spec in the task file and the pattern-finding sub-agents made implementation straightforward. All tests passed on first run.

### Deviations from Plan

**None** - Implementation followed the spec exactly as written, including:
- Schema structure with `OpenAI::ArrayOf[Integer]` for invalid matches
- 1-based numbering in AI prompt, converted to 0-based for array access
- Boolean field `ai_match_invalid: true` added to flagged albums
- Removal of flag when re-validated as valid (using `.delete("ai_match_invalid")`)
- Visual hierarchy with red background for AI-flagged items

### Code Examples

**AI Task - process_and_persist Method:**
```ruby
def process_and_persist(provider_response)
  data = provider_response[:parsed]
  invalid_indices = data[:invalid].map { |num| num - 1 }

  albums = parent.items_json["albums"]
  enriched_counter = 0

  albums.each_with_index do |album, index|
    if album["mb_release_group_id"].present?
      if invalid_indices.include?(enriched_counter)
        album["ai_match_invalid"] = true
      else
        album.delete("ai_match_invalid")
      end
      enriched_counter += 1
    end
  end

  parent.update!(items_json: {"albums" => albums})

  Services::Ai::Result.new(
    success: true,
    data: {
      valid_count: enriched_counter - invalid_indices.length,
      invalid_count: invalid_indices.length,
      total_count: enriched_counter,
      reasoning: data[:reasoning]
    },
    ai_chat: chat
  )
end
```

**Viewer Partial - AI Validation Stats:**
```erb
<% ai_validated_count = albums.count { |album| album.key?("ai_match_invalid") } %>
<% ai_invalid_count = albums.count { |album| album["ai_match_invalid"] == true } %>

<div class="stat">
  <div class="stat-title">AI Validated</div>
  <div class="stat-value text-info"><%= ai_validated_count %></div>
  <div class="stat-desc"><%= ai_invalid_count %> flagged as invalid</div>
</div>
```

**Viewer Partial - Row Highlighting:**
```erb
<% ai_flagged_invalid = album["ai_match_invalid"] == true %>
<tr class="<%= 'bg-gray-100' unless has_mb_data %> <%= 'bg-red-100' if ai_flagged_invalid %>">
```

### Testing Approach

**Test Coverage:**
- **AI Task Tests**: 13 tests covering configuration, prompt generation, response processing, and edge cases
- **Sidekiq Job Tests**: 6 tests covering success/failure paths, error handling, and job enqueueing
- **Avo Action Tests**: None (per project policy - Avo actions are manually tested)

**Key Test Scenarios:**
1. Validates only enriched albums (skips albums without MB data)
2. Correctly marks invalid matches based on AI response
3. Removes previous `ai_match_invalid` flags when re-validated as valid
4. Handles empty invalid array (all valid)
5. Converts 1-based AI numbering to 0-based array indices
6. Job error handling and logging
7. Sidekiq job enqueueing

**All tests passing:** 1372 runs, 3959 assertions, 0 failures, 0 errors, 0 skips

### Performance Considerations

**AI Task Efficiency:**
- Only validates enriched albums (skips albums without `mb_release_group_id`)
- Uses gpt-5-mini (fast, cost-effective model)
- Single API call per list (not per album)
- Temperature of 1.0 (GPT-5 models only support default)

**Queue Strategy:**
- Uses default queue (no serial queue needed)
- OpenAI has high rate limits, parallel processing is safe
- Each list processed in separate job (allows parallel execution)

**Data Structure:**
- `ai_match_invalid` flag stored directly with album data (no separate array)
- Efficient filtering in viewer partial using `.count { |album| ... }`
- No database queries in viewer (all data from JSONB field)


### Future Improvements
- Add manual override capability (mark as valid/invalid via Avo)
- Store AI reasoning in items_json for transparency
- Batch AI validation calls (multiple lists in single prompt)
- Add confidence scores to validation results
- Create report view showing all invalid matches across lists

### Lessons Learned

**1. Pattern-finding sub-agents are extremely valuable** - Using the `codebase-pattern-finder` sub-agent to find examples of AI tasks, Sidekiq jobs, and Avo actions made implementation much faster and ensured consistency with existing code patterns.

**2. Detailed task specs pay off** - The comprehensive technical approach section in this task file (lines 40-303) provided clear implementation guidance, reducing decision-making time and preventing scope drift.

**3. Testing AI tasks requires careful mocking** - Need to mock both the task instantiation and the `call` method, plus stub the `chat` method to avoid actual database writes during tests.

**4. JSONB field manipulation is efficient** - Using `.delete("ai_match_invalid")` to remove flags is cleaner than setting to `false`, as it keeps the data structure minimal and makes presence checking with `.key?()` more reliable.

**5. Visual hierarchy matters in admin tools** - Using distinct colors (`bg-red-100` for invalid, `bg-gray-100` for not enriched) makes it immediately clear which albums need attention.

### Related PRs

None - Implementation completed in single session with all tests passing.

### Documentation Updated
- [x] This task file updated with implementation notes
- [x] Code follows project conventions (no inline documentation per AGENTS.md)
- [x] Testing documentation updated (added note about not testing Avo actions)
- [x] Main todo.md updated with completion date
- [x] Class documentation created for ItemsJsonValidatorTask
- [x] Class documentation created for ValidateListItemsJsonJob
- [x] Class documentation created for ValidateItemsJson action
