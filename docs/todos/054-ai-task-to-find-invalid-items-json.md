# [054] - AI Task to Find Invalid items_json Matches

## Status
- **Status**: Not Started
- **Priority**: Medium
- **Created**: 2025-10-18
- **Started**: TBD
- **Completed**: TBD
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
- [ ] Create AI task class that validates album matches using structured validation rules
- [ ] Create Sidekiq job that invokes the AI task and updates items_json with results
- [ ] Create Avo action that launches the Sidekiq job from Music::Albums::List show page
- [ ] Update items_json viewer partial to highlight AI-flagged invalid rows with darker styling
- [ ] Handle validation results properly - update items_json with `ai_match_invalid: true` field
- [ ] Add statistics to viewer showing AI validation counts (valid/invalid/not-validated)
- [ ] Write comprehensive tests for all components

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
- [ ] AI task correctly identifies invalid matches (live vs studio, tributes, etc.)
- [ ] AI task uses structured output schema with OpenAI::BaseModel
- [ ] AI task updates items_json with `ai_match_invalid: true` for flagged albums
- [ ] Sidekiq job successfully invokes AI task and logs results
- [ ] Avo action validates lists have enriched data before queueing jobs
- [ ] Avo action provides clear error messages for invalid selections
- [ ] Viewer tool shows AI validation statistics (validated count, invalid count)
- [ ] Viewer tool highlights AI-flagged rows with red background (`bg-red-100`)
- [ ] Viewer tool shows ⚠ Invalid badge for AI-flagged albums
- [ ] AI validation takes visual precedence over enrichment status
- [ ] Tests cover all components (task, job, action)
- [ ] Tests verify items_json structure before/after validation
- [ ] Documentation updated in this file with implementation notes

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
*[This section will be filled out during/after implementation]*

### Approach Taken


### Key Files Changed


### Challenges Encountered


### Deviations from Plan


### Code Examples


### Testing Approach


### Performance Considerations


### Future Improvements
- Add manual override capability (mark as valid/invalid via Avo)
- Store AI reasoning in items_json for transparency
- Batch AI validation calls (multiple lists in single prompt)
- Add confidence scores to validation results
- Create report view showing all invalid matches across lists

### Lessons Learned


### Related PRs


### Documentation Updated
- [ ] This task file updated with implementation notes
- [ ] Code follows project conventions (no inline documentation per AGENTS.md)
- [ ] Main todo.md updated with completion date
