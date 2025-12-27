# [065] - Items JSON Viewer and AI Validation for Song Lists

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-10-30
- **Started**: 2025-10-30
- **Completed**: 2025-10-30
- **Developer**: AI (Claude)

## Overview
Create a complete items_json visualization and validation system for `Music::Songs::List` records. This task combines two components:

1. **Avo Resource Tool (Viewer)**: Displays enriched song data in a formatted table with statistics, highlighting songs missing MusicBrainz data and showing AI validation flags
2. **AI Validation Task**: Validates that MusicBrainz recording matches are correct, flagging mismatches like live vs studio recordings, covers, and different works

This mirrors the complete album implementation (tasks 053 + 054) but adapted for song-specific data structures (recordings instead of release groups).

## Context
After implementing song list enrichment in task 064, we need both visualization and validation for the data quality. The items_json field goes through stages:

1. **AI Parsing** (task 027) - Extracts songs from HTML: `{rank, title, artists, release_year}`
2. **MusicBrainz Enrichment** (task 064) - Adds metadata: `{mb_recording_id, mb_recording_name, mb_artist_ids, mb_artist_names, song_id, song_name}`
3. **AI Validation** (this task) - Flags incorrect matches: `{ai_match_invalid: true}`
4. **Visualization** (this task) - Displays all data with quality indicators

The enricher service matches songs using MusicBrainz search, but this can produce false positives:
- **Live vs Studio**: "Come Together" vs "Come Together (Live at BBC)"
- **Cover Versions**: "Johnny B. Goode" by Chuck Berry vs cover by Jimi Hendrix
- **Different Works**: "Greatest Hits" compilations that matched wrong recordings
- **Remix/Alternate Versions**: Original recording vs remix or alternate take

The complete system (viewer + validation) allows admins to:
1. See enrichment progress (statistics dashboard)
2. Identify and flag incorrect matches (AI validation)
3. Review flagged items before import (visual highlighting)
4. Re-run validation as needed (action button)

### Related Work
- **Task 053**: Implemented items_json viewer for albums - viewer pattern to follow
- **Task 054**: Implemented AI validation for albums - validation pattern to follow
- **Task 064**: Implemented song list enrichment - provides the data we'll validate/display
- **Future Task**: Import songs and create list_items from validated items_json (similar to task 055)

## Requirements

### Part 1: Viewer Tool
- [ ] Create Avo resource tool class for song viewer
- [ ] Create ERB partial view with statistics and table
- [ ] Display total songs, enriched count, missing count statistics
- [ ] Include AI validation statistics (validated count, invalid count)
- [ ] Show detailed table with all song data fields
- [ ] Highlight rows with missing MusicBrainz data (gray background)
- [ ] Highlight AI-flagged invalid matches (red background, takes precedence)
- [ ] Display three-state status badges (✓ valid, ✗ missing, ⚠ invalid)
- [ ] Handle empty items_json gracefully with info alert
- [ ] Register tool in Music::Songs::List Avo resource

### Part 2: AI Validation
- [ ] Create AI task class that validates song matches using structured validation rules
- [ ] Implement validation criteria for live vs studio, covers, remixes, different works
- [ ] Use OpenAI gpt-5-mini with structured output (OpenAI::BaseModel)
- [ ] Return array of invalid match numbers with reasoning
- [ ] Update items_json with `ai_match_invalid: true` field for flagged songs
- [ ] Create Sidekiq job that invokes AI task and updates items_json with results
- [ ] Create Avo action that launches Sidekiq job from Music::Songs::List show page
- [ ] Validate lists have enriched data before queueing validation jobs
- [ ] Write comprehensive tests for AI task and Sidekiq job
- [ ] Handle edge cases: empty lists, all valid, all invalid, re-validation

## Technical Approach

### Pattern to Follow
This implementation should **closely mirror** the album viewer from task 053/054. The files to reference:
- `/home/shane/dev/the-greatest/web-app/app/avo/resource_tools/lists/music/albums/items_json_viewer.rb` - Resource tool class
- `/home/shane/dev/the-greatest/web-app/app/views/avo/resource_tools/lists/music/albums/_items_json_viewer.html.erb` - ERB partial
- `/home/shane/dev/the-greatest/web-app/app/avo/resources/music_albums_list.rb:9` - Tool registration

### 1. Resource Tool Class

**Location**: `app/avo/resource_tools/lists/music/songs/items_json_viewer.rb`

**Implementation**:
```ruby
class Avo::ResourceTools::Lists::Music::Songs::ItemsJsonViewer < Avo::BaseResourceTool
  self.name = "Items JSON Viewer"
  self.partial = "avo/resource_tools/lists/music/songs/items_json_viewer"
end
```

**Pattern Notes**:
- Identical structure to album viewer
- Only differences: namespace (`Songs` vs `Albums`) and partial path
- No custom logic needed - all logic in partial

### 2. ERB Partial View

**Location**: `app/views/avo/resource_tools/lists/music/songs/_items_json_viewer.html.erb`

**Structure** (copy album viewer and adapt):

#### Data Extraction & Validation (Lines 1-2)
```erb
<% if @resource.record.items_json.present? && @resource.record.items_json["songs"]&.any? %>
  <% songs = @resource.record.items_json["songs"] %>
```

**Changes from albums**:
- Check `items_json["songs"]` instead of `items_json["albums"]`
- Use `songs` variable instead of `albums`

#### Statistics Calculation (Lines 3-9)
```erb
  <% total_count = songs.length %>
  <% enriched_count = songs.count { |song| song["mb_recording_id"].present? } %>
  <% missing_count = total_count - enriched_count %>
  <% enrichment_percentage = total_count > 0 ? (enriched_count.to_f / total_count * 100).round : 0 %>
  <% ai_validated_count = songs.count { |song| song.key?("ai_match_invalid") } %>
  <% ai_invalid_count = songs.count { |song| song["ai_match_invalid"] == true } %>
  <% ai_valid_count = ai_validated_count - ai_invalid_count %>
```

**Changes from albums**:
- Use `songs` array instead of `albums`
- Check for `mb_recording_id` instead of `mb_release_group_id`

#### Statistics Display (Lines 11-37)
Four DaisyUI statistics cards:

1. **Total Songs**
   - Title: "Total Songs"
   - Value: `total_count` with `text-primary` color

2. **Enriched with MusicBrainz**
   - Title: "Enriched with MusicBrainz"
   - Value: `enriched_count` with `text-success` color
   - Description: "X% complete"

3. **Missing MusicBrainz Data**
   - Title: "Missing MusicBrainz Data"
   - Value: `missing_count` with `text-error` color
   - Description: "X% remaining"

4. **AI Validated**
   - Title: "AI Validated"
   - Value: `ai_validated_count` with `text-info` color
   - Description: "X flagged as invalid"

**Changes from albums**:
- "Total Songs" instead of "Total Albums"
- All other logic identical

#### Table Headers (Lines 42-51)
```erb
<thead>
  <tr>
    <th class="border border-gray-300">Status</th>
    <th class="border border-gray-300">Rank</th>
    <th class="border border-gray-300">Title</th>
    <th class="border border-gray-300">Artists</th>
    <th class="border border-gray-300">Year</th>
    <th class="border border-gray-300">MusicBrainz Recording</th>
    <th class="border border-gray-300">MusicBrainz Artists</th>
    <th class="border border-gray-300">Database Song</th>
  </tr>
</thead>
```

**Changes from albums**:
- "MusicBrainz Recording" instead of "MusicBrainz Release Group"
- "Database Song" instead of "Database Album"

#### Row Rendering Loop (Lines 54-95)
```erb
<% songs.sort_by { |s| s["rank"] || 0 }.each do |song| %>
  <% has_mb_data = song["mb_recording_id"].present? %>
  <% ai_flagged_invalid = song["ai_match_invalid"] == true %>
  <tr class="<%= 'bg-gray-100' unless has_mb_data %> <%= 'bg-red-100' if ai_flagged_invalid %>">
```

**Changes from albums**:
- Iterate over `songs` instead of `albums`
- Check `mb_recording_id` instead of `mb_release_group_id`
- All highlighting logic identical

#### Status Badge (Lines 58-66)
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

**No changes** - badge logic is identical for songs

#### Basic Fields (Lines 67-70)
```erb
<td class="text-center font-bold border border-gray-300"><%= song["rank"] || '-' %></td>
<td class="font-semibold border border-gray-300"><%= song["title"] || '-' %></td>
<td class="border border-gray-300"><%= Array(song["artists"]).join(", ").presence || '-' %></td>
<td class="text-center border border-gray-300"><%= song["release_year"] || '-' %></td>
```

**Changes from albums**:
- Use `song` variable instead of `album`
- All logic identical

#### MusicBrainz Recording Column (Lines 71-78)
```erb
<td class="border border-gray-300">
  <% if song["mb_recording_id"].present? %>
    <div class="text-xs font-mono text-gray-600"><%= song["mb_recording_id"] %></div>
    <div class="text-sm"><%= song["mb_recording_name"] %></div>
  <% else %>
    <span class="text-gray-400">-</span>
  <% end %>
</td>
```

**Changes from albums**:
- Use `mb_recording_id` instead of `mb_release_group_id`
- Use `mb_recording_name` instead of `mb_release_group_name`

#### MusicBrainz Artists Column (Lines 79-86)
```erb
<td class="border border-gray-300">
  <% if song["mb_artist_ids"].present? %>
    <div class="text-xs font-mono text-gray-600"><%= Array(song["mb_artist_ids"]).join(", ") %></div>
    <div class="text-sm"><%= Array(song["mb_artist_names"]).join(", ") %></div>
  <% else %>
    <span class="text-gray-400">-</span>
  <% end %>
</td>
```

**No changes** - artist fields are identical for songs and albums

#### Database Song Column (Lines 87-94)
```erb
<td class="border border-gray-300">
  <% if song["song_id"].present? %>
    <div class="text-xs font-mono text-gray-600">ID: <%= song["song_id"] %></div>
    <div class="text-sm"><%= song["song_name"] %></div>
  <% else %>
    <span class="text-gray-400">-</span>
  <% end %>
</td>
```

**Changes from albums**:
- Use `song_id` instead of `album_id`
- Use `song_name` instead of `album_name`

#### Empty State (Lines 103-112)
```erb
<% else %>
  <%= render Avo::PanelComponent.new(title: "Items JSON Viewer") do |c| %>
    <% c.with_body do %>
      <div class="alert alert-info m-4">
        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
        </svg>
        <span>No items_json data available for this list.</span>
      </div>
    <% end %>
  <% end %>
<% end %>
```

**No changes** - empty state is identical

### 3. Resource Registration

**Location**: `app/avo/resources/music_songs_list.rb`

**Add to `fields` method** (after line 8):
```ruby
def fields
  super

  field :musicbrainz_series_id, as: :text, help: "MusicBrainz Series ID for importing songs from series", show_on: [:show, :edit, :new]

  tool Avo::ResourceTools::Lists::Music::Songs::ItemsJsonViewer  # Add this line
end
```

**Pattern**: Identical to album resource registration

### 4. AI Validation Task Implementation

**Location**: `app/lib/services/ai/tasks/lists/music/songs/items_json_validator_task.rb`

**Pattern**: Follows `Services::Ai::Tasks::Lists::Music::Albums::ItemsJsonValidatorTask` exactly

**Class Structure**:
```ruby
module Services
  module Ai
    module Tasks
      module Lists
        module Music
          module Songs
            class ItemsJsonValidatorTask < Services::Ai::Tasks::BaseTask
              private

              def task_provider = :openai
              def task_model = "gpt-5-mini"
              def chat_type = :analysis
              def temperature = 1.0

              def system_message
                # Validation criteria for song matches
              end

              def user_prompt
                # Build prompt with numbered list of song matches
              end

              def response_format = {type: "json_object"}

              def response_schema
                ResponseSchema
              end

              def process_and_persist(provider_response)
                # Extract invalid indices, update items_json, return results
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

**Key Implementation Details**:

1. **System Message** - Define validation criteria:
   - Live vs Studio recordings (e.g., "Imagine" ≠ "Imagine (Live)")
   - Cover versions (e.g., original by Artist A ≠ cover by Artist B)
   - Different recordings with similar titles
   - Remix/alternate versions (e.g., album version ≠ remix)
   - Artist mismatches suggesting different works

2. **User Prompt** - Format: `{number}. Original: "artist - title" → Matched: "matched_artist - matched_title"`
   - Only include enriched songs (`mb_recording_id` present)
   - Use 1-based numbering for AI (convert to 0-based for array access)
   - Join artist arrays with commas

3. **Process and Persist**:
   ```ruby
   def process_and_persist(provider_response)
     data = provider_response[:parsed]
     invalid_indices = data[:invalid].map { |num| num - 1 }  # 1-based to 0-based

     songs = parent.items_json["songs"]
     enriched_counter = 0

     songs.each_with_index do |song, index|
       if song["mb_recording_id"].present?
         if invalid_indices.include?(enriched_counter)
           song["ai_match_invalid"] = true
         else
           song.delete("ai_match_invalid")  # Remove flag if re-validated as valid
         end
         enriched_counter += 1
       end
     end

     parent.update!(items_json: {"songs" => songs})

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

**Changes from Albums**:
- Use `"songs"` instead of `"albums"` key
- Check `mb_recording_id` instead of `mb_release_group_id`
- Use `mb_recording_name` instead of `mb_release_group_name`
- Validation criteria adapted for recordings (live, covers, remixes vs live albums, tributes, compilations)

### 5. Sidekiq Job Implementation

**Location**: `app/sidekiq/music/songs/validate_list_items_json_job.rb`

**Pattern**: Follows `Music::Albums::ValidateListItemsJsonJob` exactly

**Generate with**:
```bash
cd web-app
bin/rails generate sidekiq:job music/songs/validate_list_items_json
```

**Class Structure**:
```ruby
class Music::Songs::ValidateListItemsJsonJob
  include Sidekiq::Job

  def perform(list_id)
    list = ::Music::Songs::List.find(list_id)

    result = Services::Ai::Tasks::Lists::Music::Songs::ItemsJsonValidatorTask.new(parent: list).call

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
- Use default queue (not serial) - OpenAI has high rate limits
- Task handles all items_json updates internally
- Log validation counts for monitoring
- Re-raise exceptions to mark job as failed in Sidekiq

**Changes from Albums**:
- Namespace: `Music::Songs` instead of `Music::Albums`
- Model: `::Music::Songs::List` instead of `::Music::Albums::List`
- Task: `ItemsJsonValidatorTask` in `Songs` namespace

### 6. Avo Action Implementation

**Location**: `app/avo/actions/lists/music/songs/validate_items_json.rb`

**Pattern**: Follows `Avo::Actions::Lists::Music::Albums::ValidateItemsJson` exactly

**Class Structure**:
```ruby
class Avo::Actions::Lists::Music::Songs::ValidateItemsJson < Avo::BaseAction
  self.name = "Validate items_json matches with AI"
  self.message = "This will use AI to validate that MusicBrainz matches in items_json are correct. Invalid matches will be flagged in the data."
  self.confirm_button_label = "Validate matches"

  def handle(query:, fields:, current_user:, resource:, **args)
    query.pluck(:id)

    valid_lists = query.select do |list|
      is_song_list = list.is_a?(::Music::Songs::List)
      has_enriched_items = list.items_json.present? &&
        list.items_json["songs"].is_a?(Array) &&
        list.items_json["songs"].any? { |s| s["mb_recording_id"].present? }

      unless is_song_list
        Rails.logger.warn "Skipping non-song list: #{list.name} (ID: #{list.id}, Type: #{list.class})"
      end

      unless has_enriched_items
        Rails.logger.warn "Skipping list without enriched items_json: #{list.name} (ID: #{list.id})"
      end

      is_song_list && has_enriched_items
    end

    if valid_lists.empty?
      return error "No valid lists found. Lists must be Music::Songs::List with enriched items_json data."
    end

    valid_lists.each do |list|
      Music::Songs::ValidateListItemsJsonJob.perform_async(list.id)
    end

    succeed "#{valid_lists.length} list(s) queued for AI validation. Each list will be processed in a separate background job."
  end
end
```

**Key Decisions**:
- Require enriched data (must have `mb_recording_id` on at least one song)
- Validate both list type AND data availability
- Log warnings for skipped lists
- Use descriptive error messages

**Registration**: Add to `app/avo/resources/music_songs_list.rb`:
```ruby
def actions
  super

  action Avo::Actions::Lists::ImportFromMusicbrainzSeries
  action Avo::Actions::Lists::Music::Songs::EnrichItemsJson
  action Avo::Actions::Lists::Music::Songs::ValidateItemsJson  # Add this line
end
```

**Changes from Albums**:
- Namespace: `Songs` instead of `Albums`
- Check: `is_a?(::Music::Songs::List)` instead of `Music::Albums::List`
- Check: `items_json["songs"]` instead of `items_json["albums"]`
- Check: `mb_recording_id` instead of `mb_release_group_id`
- Job: `Music::Songs::ValidateListItemsJsonJob` instead of `Music::Albums::ValidateListItemsJsonJob`

## Data Structure Reference

### items_json Structure for Songs

**After Parsing (task 027)**:
```json
{
  "songs": [
    {
      "rank": 1,
      "title": "Come Together",
      "artists": ["The Beatles"],
      "release_year": 1969
    }
  ]
}
```

**After Enrichment (task 064)**:
```json
{
  "songs": [
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
      "song_name": "Come Together"
    }
  ]
}
```

**After AI Validation (future task, similar to 054)**:
```json
{
  "songs": [
    {
      "rank": 1,
      "title": "Come Together",
      "artists": ["The Beatles"],
      "release_year": 1969,
      "mb_recording_id": "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
      "mb_recording_name": "Come Together (Live)",
      "mb_artist_ids": ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"],
      "mb_artist_names": ["The Beatles"],
      "song_id": 123,
      "song_name": "Come Together",
      "ai_match_invalid": true
    }
  ]
}
```

## Field Mapping: Albums vs Songs

| Purpose | Albums | Songs |
|---------|--------|-------|
| items_json key | `"albums"` | `"songs"` |
| MusicBrainz ID field | `mb_release_group_id` | `mb_recording_id` |
| MusicBrainz name field | `mb_release_group_name` | `mb_recording_name` |
| Database ID field | `album_id` | `song_id` |
| Database name field | `album_name` | `song_name` |
| Artist fields | `mb_artist_ids`, `mb_artist_names` | `mb_artist_ids`, `mb_artist_names` (same) |
| AI validation field | `ai_match_invalid` | `ai_match_invalid` (same) |

## Dependencies
- Existing: `Music::Songs::List` model with `items_json` JSONB field
- Existing: `Services::Lists::Music::Songs::ItemsJsonEnricher` (task 064) - populates the data
- Existing: `Avo::BaseResourceTool` - base class for resource tools
- Existing: `Avo::PanelComponent` - wrapper component for consistent styling
- Reference: Album viewer implementation (tasks 053, 054) - pattern to follow
- Future: AI validation task for songs (will add `ai_match_invalid` flags)

## Acceptance Criteria

### Part 1: Viewer Tool
- [ ] Resource tool class created and inherits from Avo::BaseResourceTool
- [ ] ERB partial renders statistics showing total, enriched, missing, and AI validated counts
- [ ] ERB partial renders table with 8 columns (status, rank, title, artists, year, MB recording, MB artists, DB song)
- [ ] Table rows highlighted with gray background when missing MusicBrainz data
- [ ] Table rows highlighted with red background when AI flagged as invalid (takes precedence)
- [ ] Status badges show three states: ✓ (valid), ✗ (missing), ⚠ Invalid (AI flagged)
- [ ] MusicBrainz recording ID and name displayed when present
- [ ] MusicBrainz artist IDs and names displayed when present
- [ ] Database song ID and name displayed when song exists locally
- [ ] Empty state alert shown when items_json is nil or empty
- [ ] Tool registered in Music::Songs::List Avo resource
- [ ] Viewer accessible on song list show page in Avo admin
- [ ] DaisyUI components render correctly (stats cards, table, badges, alerts)
- [ ] Responsive layout works on mobile and desktop
- [ ] Code follows existing patterns from album viewer

### Part 2: AI Validation
- [ ] AI task correctly identifies invalid matches (live vs studio, covers, remixes, different works)
- [ ] AI task uses structured output schema with OpenAI::BaseModel
- [ ] AI task uses OpenAI gpt-5-mini for cost-effective validation
- [ ] AI task updates items_json with `ai_match_invalid: true` for flagged songs
- [ ] AI task removes `ai_match_invalid` flag when re-validated as valid
- [ ] AI task only validates enriched songs (skips songs without MB data)
- [ ] AI task returns result with valid/invalid/total counts and reasoning
- [ ] Sidekiq job successfully invokes AI task and logs results
- [ ] Sidekiq job handles errors and re-raises for retry mechanism
- [ ] Avo action validates lists have enriched data before queueing jobs
- [ ] Avo action provides clear error messages for invalid selections
- [ ] Avo action registered in Music::Songs::List resource actions
- [ ] Tests cover all AI task scenarios (valid, invalid, edge cases)
- [ ] Tests cover Sidekiq job success/failure paths
- [ ] Tests verify items_json structure before/after validation
- [ ] All tests passing with 100% coverage for new code

## Design Decisions

### 1. Duplication Over Abstraction
**Decision**: Duplicate the album viewer implementation rather than extract shared components.
**Rationale**: The codebase uses this pattern (no shared Avo helpers/partials exist). Duplication makes each viewer self-contained and easier to maintain. Abstraction can be added later if a third viewer is needed (e.g., movies/books).
**Trade-off**: Some duplicated code, but better clarity and independence.

### 2. AI Validation Support from Start
**Decision**: Include AI validation statistics and highlighting even though AI task doesn't exist yet.
**Rationale**: Album viewer was enhanced with this in task 054. Including it from the start prepares for future AI validation task and maintains consistency with albums.
**Alternative Considered**: Add AI support later (rejected - easier to include now while building).

### 3. Field Name Consistency
**Decision**: Use `mb_recording_id` and `mb_recording_name` for MusicBrainz fields.
**Rationale**: Mirrors the enricher service (task 064) and follows MusicBrainz terminology (recordings vs release groups).
**Alternative Considered**: Use generic names like `mb_id` (rejected - loses domain specificity).

### 4. Table Column Structure
**Decision**: Use 8 columns identical to album viewer structure.
**Rationale**: Consistent UI across album and song viewers. Users familiar with one will understand the other.
**Alternative Considered**: Different column order or grouping (rejected - consistency more valuable).

### 5. Visual Hierarchy
**Decision**: Red background for AI-flagged invalid > gray for not enriched > white for valid.
**Rationale**: Matches album viewer. Most critical issues (AI flags) are most visible.
**Trade-off**: Red is attention-grabbing, appropriate for data quality issues.

### 6. Responsive Layout
**Decision**: Use DaisyUI responsive classes (`lg:stats-horizontal`, `overflow-x-auto`).
**Rationale**: Matches album viewer. Mobile-first approach with horizontal stats on larger screens.
**Implementation**: Stats cards stack vertically on mobile, table scrolls horizontally.

### 7. Empty State Messaging
**Decision**: Show info alert with "No items_json data available for this list."
**Rationale**: Clear, non-technical message. Consistent with album viewer.
**Alternative Considered**: Show example data structure (rejected - too technical for admin UI).

### 8. No Testing for Viewer
**Decision**: No automated tests for resource tools (viewer only).
**Rationale**: Resource tools are view-layer components tested through manual inspection in Avo admin. Matches project policy (see docs/testing.md). Album viewer has no tests.
**Note**: AI validation task and job WILL have comprehensive tests (following task 054 pattern).

### 9. Panel Title
**Decision**: Use "Items JSON Viewer" as panel title.
**Rationale**: Generic name works for both albums and songs. Consistent across viewers.
**Alternative Considered**: "Songs Data Viewer" (rejected - less consistent with albums).

### 10. Statistics Precision
**Decision**: Round enrichment percentage to integer (no decimal places).
**Rationale**: Matches album viewer. Sufficient precision for admin dashboard.
**Implementation**: `(enriched_count.to_f / total_count * 100).round`

### 11. Combined Implementation
**Decision**: Implement viewer and AI validation together in single task.
**Rationale**: Viewer already includes AI validation UI (stats, highlighting). Implementing validation at the same time allows end-to-end testing of complete workflow. Avoids having dormant UI features.
**Alternative Considered**: Separate tasks like albums (053 + 054) - rejected for efficiency.

### 12. Virtual Numbering for AI Response
**Decision**: Use index+1 numbering in AI prompt, convert back to 0-based indices.
**Rationale**: AI models work better with 1-based numbering (more natural). We convert back to 0-based for array access.
**Trade-off**: Requires conversion logic but improves AI accuracy.

### 13. Structured Output Schema
**Decision**: Use `OpenAI::BaseModel` with typed schema for AI responses.
**Rationale**: Ensures reliable parsing, automatic validation, type safety. Matches album validation pattern.
**Alternative Considered**: Free-form JSON with manual parsing (rejected - error-prone).

### 14. Flagging Strategy
**Decision**: Add `ai_match_invalid: true` to each song object, delete flag when re-validated as valid.
**Rationale**: Keeps validation state with the data, easier to filter/query, simpler partial logic. Using `.delete()` instead of setting to false keeps data structure minimal.
**Alternative Considered**: Separate array of invalid indices (rejected - harder to maintain sync).

### 15. Validation Scope
**Decision**: Only validate songs with `mb_recording_id` present.
**Rationale**: Can't validate matches that don't exist. Enrichment must happen first.
**Implementation**: Action checks for enriched data before queueing job, task skips non-enriched songs.

### 16. Re-validation Strategy
**Decision**: Allow re-running validation (overwrites `ai_match_invalid` flags).
**Rationale**: Rules may change, data may improve, false positives need correction.
**Implementation**: Task processes all enriched songs, adds/updates/removes flag as needed.

### 17. Reasoning Field
**Decision**: Include optional `reasoning` field in AI response schema.
**Rationale**: Helps debugging, transparency for why matches were flagged.
**Trade-off**: Slightly more tokens used, but valuable for understanding AI decisions.

### 18. Job Queue Selection
**Decision**: Use default queue (not serial) for validation jobs.
**Rationale**: No rate limiting needed (OpenAI has high rate limits), validation can run in parallel.
**Alternative Considered**: Serial queue for AI calls (rejected - unnecessary bottleneck).

## Implementation Checklist

### 1. Create Resource Tool Class
- [ ] Create file: `app/avo/resource_tools/lists/music/songs/items_json_viewer.rb`
- [ ] Inherit from `Avo::BaseResourceTool`
- [ ] Set `self.name = "Items JSON Viewer"`
- [ ] Set `self.partial` to point to ERB template
- [ ] Follow exact pattern from album viewer

### 2. Create ERB Partial
- [ ] Create directory: `app/views/avo/resource_tools/lists/music/songs/`
- [ ] Create file: `_items_json_viewer.html.erb`
- [ ] Copy album viewer partial as starting point
- [ ] Replace `"albums"` with `"songs"` throughout
- [ ] Replace `mb_release_group_id` with `mb_recording_id`
- [ ] Replace `mb_release_group_name` with `mb_recording_name`
- [ ] Replace `album_id`/`album_name` with `song_id`/`song_name`
- [ ] Update statistics labels ("Total Songs" vs "Total Albums")
- [ ] Update table headers ("MusicBrainz Recording", "Database Song")
- [ ] Verify variable names (`song` vs `album`, `songs` vs `albums`)
- [ ] Verify all conditional checks use song-specific fields
- [ ] Test rendering with empty items_json
- [ ] Test rendering with partial items_json (no enrichment)
- [ ] Test rendering with full enrichment
- [ ] Test rendering with AI validation flags

### 3. Register Tool in Resource
- [ ] Open `app/avo/resources/music_songs_list.rb`
- [ ] Add tool registration to `fields` method
- [ ] Add after existing field definitions
- [ ] Format: `tool Avo::ResourceTools::Lists::Music::Songs::ItemsJsonViewer`
- [ ] Save file

### 4. Create AI Validation Task
- [ ] Create file: `app/lib/services/ai/tasks/lists/music/songs/items_json_validator_task.rb`
- [ ] Copy album validator task as starting point
- [ ] Update namespace to `Songs` instead of `Albums`
- [ ] Update system message with song-specific validation criteria
- [ ] Update user prompt to use `"songs"` array and `mb_recording_id`/`mb_recording_name`
- [ ] Update process_and_persist to use song fields
- [ ] Verify ResponseSchema uses `OpenAI::ArrayOf[Integer]`
- [ ] Test with Mocha mocks for OpenAI API

### 5. Create Sidekiq Job for Validation
- [ ] Generate job: `bin/rails generate sidekiq:job music/songs/validate_list_items_json`
- [ ] Implement `perform(list_id)` method
- [ ] Load `::Music::Songs::List` and call validator task
- [ ] Add success/failure logging with validation counts
- [ ] Add error handling and re-raise exceptions
- [ ] Test job execution, enqueueing, and error handling

### 6. Create Avo Action for Validation
- [ ] Create file: `app/avo/actions/lists/music/songs/validate_items_json.rb`
- [ ] Inherit from `Avo::BaseAction`
- [ ] Set name, message, confirm button label
- [ ] Implement `handle` method with list validation
- [ ] Check lists are `Music::Songs::List` type
- [ ] Check lists have enriched items_json (`mb_recording_id` present)
- [ ] Log warnings for skipped lists
- [ ] Queue job for each valid list
- [ ] Return success/error messages
- [ ] Register action in `music_songs_list.rb` actions method

### 7. Write Tests for AI Task
- [ ] Create file: `test/lib/services/ai/tasks/lists/music/songs/items_json_validator_task_test.rb`
- [ ] Test task configuration (provider, model, chat_type, temperature)
- [ ] Test system message contains validation criteria
- [ ] Test user prompt generation with song matches
- [ ] Test process_and_persist marks invalid songs correctly
- [ ] Test process_and_persist removes flags when re-validated as valid
- [ ] Test only enriched songs are validated
- [ ] Test 1-based to 0-based index conversion
- [ ] Test empty invalid array (all valid)
- [ ] Test all invalid
- [ ] Test result data structure (valid_count, invalid_count, total_count, reasoning)
- [ ] Mock OpenAI API responses with Mocha
- [ ] Aim for 100% coverage

### 8. Write Tests for Sidekiq Job
- [ ] Create file: `test/sidekiq/music/songs/validate_list_items_json_job_test.rb`
- [ ] Test successful job execution with logging
- [ ] Test failed validation logging
- [ ] Test list not found error handling
- [ ] Test unexpected error handling
- [ ] Test job enqueueing with Sidekiq::Testing.fake!
- [ ] Test correct list loading
- [ ] Aim for 100% coverage

### 9. Manual Testing in Avo - Full Workflow
- [ ] Start Rails server and Avo admin
- [ ] Navigate to Music::Songs::List index
- [ ] Find a list with enriched items_json
- [ ] Click to view list show page
- [ ] Verify "Items JSON Viewer" panel appears
- [ ] Verify statistics cards display correct counts
- [ ] Verify table renders with all columns
- [ ] Verify rows without enrichment have gray background
- [ ] Run "Enrich items_json" action if needed
- [ ] Run "Validate items_json matches with AI" action
- [ ] Verify action success message
- [ ] Wait for background job to complete
- [ ] Refresh page and verify AI validation statistics update
- [ ] Verify red background for AI-flagged invalid matches
- [ ] Verify warning badge displays for invalid matches
- [ ] Test re-validation (run action again)
- [ ] Compare to album viewer for consistency

### 10. Edge Case Testing
- [ ] Test with nil items_json
- [ ] Test with empty items_json `{}`
- [ ] Test with items_json missing "songs" key
- [ ] Test with empty songs array `{"songs": []}`
- [ ] Test with songs missing ranks (should use 0 for sorting)
- [ ] Test with songs missing titles, artists, years (should show `-`)
- [ ] Test with multi-artist songs (comma-separated display)
- [ ] Test with very long artist/title names (overflow handling)
- [ ] Test with many songs (100+) - table scrolling
- [ ] Test validation action on non-enriched list (should error)
- [ ] Test validation action on wrong list type (should skip)
- [ ] Test with mix of validated and non-validated songs

## Performance Considerations

### View Rendering
- All calculations done in-memory from JSONB field
- No database queries in the view (songs already loaded in items_json)
- Statistics calculations: O(n) where n = number of songs in list
- Sorting: O(n log n) for rank-based sort

### AI Validation
- Only validates enriched songs (skips songs without `mb_recording_id`)
- Uses gpt-5-mini (fast, cost-effective model)
- Single API call per list (not per song)
- Temperature of 1.0 (GPT-5 models only support default)
- Default queue (no serial queue needed - OpenAI has high rate limits)
- Each list processed in separate job (allows parallel execution)

### Data Structure
- `ai_match_invalid` flag stored directly with song data (no separate array)
- Efficient filtering in viewer partial using `.count { |song| ... }`
- No database queries in viewer (all data from JSONB field)

### Data Size
- Typical list: 50-500 songs
- Large list: 1000+ songs
- items_json field loaded once from database
- All rendering happens in-memory

### Optimization Opportunities
- **Not needed initially**: View and validation performance should be fine for typical use
- **If needed later**: Could add pagination for very large lists (1000+ songs)
- **If needed later**: Could cache statistics calculations (memoization)
- **If needed later**: Batch AI validation calls (multiple lists in single prompt)

## Future Enhancements

### Phase 2: Import Feature
Create import service for songs (similar to task 055 for albums) that:
- Automatically imports missing songs from validated items_json
- Creates list_items linking songs to lists
- Handles duplicate detection

### Phase 3: Interactive Features
- Click to expand row and show full MusicBrainz metadata
- Link database song ID to song show page
- Link MusicBrainz IDs to musicbrainz.org
- Inline editing to fix incorrect matches
- Bulk actions to re-enrich or validate

### Phase 4: Export Features
- Export table as CSV
- Export MusicBrainz IDs as text list
- Generate import report

### Phase 5: Code Reuse
If a third viewer is needed (movies/books), consider:
- Extract shared partial for statistics cards
- Create helper methods for status badges
- Extract shared empty state component
- Consider ViewComponent refactor

## Related Tasks

- **Prerequisite**: [064 - Enrich Song List items_json with MusicBrainz Data](064-import-song-list-from-musicbrainz-non-series.md) - Provides the data we'll validate and display
- **Pattern**: [053 - Items JSON Viewer Resource Tool](053-items-json-viewer-resource-tool.md) - Album viewer pattern for songs viewer
- **Pattern**: [054 - AI Task to Find Invalid items_json Matches](054-ai-task-to-find-invalid-items-json.md) - Album AI validation pattern for songs validation
- **Future**: [055 - Import Albums and Create list_items from items_json](055-import-items-from-list-items-json.md) - Import pattern to follow for songs (Phase 2)

## Implementation Notes

### Approach Taken
Followed the exact pattern from tasks 053 (album viewer) and 054 (album AI validation), adapting field names and validation criteria for song recordings instead of release groups. The implementation was straightforward duplication with song-specific modifications.

### Key Files Changed

**Part 1: Viewer Tool**
- `app/avo/resource_tools/lists/music/songs/items_json_viewer.rb` - Resource tool class (NEW)
- `app/views/avo/resource_tools/lists/music/songs/_items_json_viewer.html.erb` - ERB partial view (NEW)
- `app/avo/resources/music_songs_list.rb` - Added tool registration (MODIFIED)

**Part 2: AI Validation**
- `app/lib/services/ai/tasks/lists/music/songs/items_json_validator_task.rb` - AI validation task (NEW)
- `app/sidekiq/music/songs/validate_list_items_json_job.rb` - Sidekiq job (NEW)
- `app/avo/actions/lists/music/songs/validate_items_json.rb` - Avo action (NEW)
- `app/avo/resources/music_songs_list.rb` - Added action registration (MODIFIED)

**Part 3: Tests**
- `test/lib/services/ai/tasks/lists/music/songs/items_json_validator_task_test.rb` - AI task tests (NEW)
- `test/sidekiq/music/songs/validate_list_items_json_job_test.rb` - Sidekiq job tests (NEW)

### Challenges Encountered

**Bundle Install Required**: Had to run `bundle install` before generating Sidekiq job due to missing gems (avo-3.25.3, timeout-0.4.4, rake-13.3.1, date-3.5.0). This was resolved by running bundle install in web-app directory.

**No Other Challenges**: The implementation followed the album pattern so closely that no unexpected issues arose. All tests passed on first run.

### Deviations from Plan
None. The implementation followed the detailed plan exactly, with all files created in the locations specified and following the patterns documented in the task file.

### Code Examples

**Key Field Differences (Albums vs Songs)**:
```ruby
# Albums use:
album["mb_release_group_id"]
album["mb_release_group_name"]

# Songs use:
song["mb_recording_id"]
song["mb_recording_name"]
```

**AI Validation Criteria for Songs**:
```ruby
# system_message excerpt
A match is INVALID if:
- Live recordings are matched with studio recordings (e.g., "Imagine" ≠ "Imagine (Live)")
- Cover versions are matched with originals (e.g., original by Artist A ≠ cover by Artist B)
- Different recordings with similar titles (e.g., "Johnny B. Goode" by Chuck Berry ≠ by Jimi Hendrix)
- Remix or alternate versions are matched with originals (e.g., album version ≠ remix)
- Significant artist name differences suggesting different works
```

### Testing Approach

**Comprehensive Test Coverage**:
- 13 tests for AI validation task covering configuration, prompt generation, validation logic, and edge cases
- 6 tests for Sidekiq job covering success/failure paths, enqueueing, and error handling
- All tests use Mocha for mocking OpenAI API responses
- Tests verify both normal operation and edge cases (empty lists, all valid, all invalid, re-validation)

**Test Results**: 1525 runs, 4374 assertions, 0 failures, 0 errors, 0 skips

### Performance Considerations

**Same as Albums**:
- Viewer renders from JSONB field (no database queries in view)
- AI validation uses single API call per list (not per song)
- Uses gpt-5-mini for cost-effective, fast validation
- Default queue (no serial processing needed)
- Each list processed in separate background job for parallel execution

### Future Improvements

**Phase 2**: Import songs from validated items_json (similar to task 055 for albums)
- Automatically import missing songs
- Create list_items linking songs to lists
- Handle duplicate detection

**Phase 3**: Interactive features
- Click to expand rows with full MusicBrainz metadata
- Link to MusicBrainz.org and database song pages
- Inline editing for incorrect matches
- Bulk re-enrichment actions

### Lessons Learned

**Duplication vs Abstraction**: Following the album pattern with minimal changes proved faster and clearer than attempting to abstract shared components. The task documentation's recommendation to duplicate first was correct - abstraction can come later if a third viewer is needed.

**Comprehensive Planning Pays Off**: The extremely detailed task file (944 lines) made implementation trivial. Having exact file locations, field mappings, and pattern references eliminated all decision-making during coding.

**Test Pattern Consistency**: Using identical test structure between albums and songs made test creation mechanical. This consistency will help future developers understand test patterns across the codebase.

### Related PRs
Implementation completed in single session without PR (direct to main).

### Documentation Updated
- [x] This task file updated with implementation notes
- [x] Code follows project conventions (no inline documentation per AGENTS.md)
- [x] Main todo.md updated with task status
- [x] Class documentation created for all new classes:
  - `docs/avo/resource_tools/lists/music/songs/items_json_viewer.md`
  - `docs/lib/services/ai/tasks/lists/music/songs/items_json_validator_task.md`
  - `docs/sidekiq/music/songs/validate_list_items_json_job.md`
  - `docs/avo/actions/lists/music/songs/validate_items_json.md`
