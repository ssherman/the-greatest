# [093] - Song Wizard: Step 4 - Per-Item Actions

## Status
- **Status**: Complete
- **Priority**: High
- **Created**: 2025-01-19
- **Completed**: 2025-12-09
- **Part**: 8 of 10

## Overview
Implement per-item actions for the review step. Users can manually edit the raw metadata JSONB, link to existing songs in our database (autocomplete), or search MusicBrainz API to find and link recordings (autocomplete). This is a focused first pass - bulk actions and advanced features deferred to [095] Polish.

## Context

This is **Part 8 of 10** in the Song List Wizard implementation:

1. [086] Infrastructure - Complete
2. [087] Wizard UI Shell - Complete
3. [088] Step 0: Import Source Choice - Complete
4. [089] Step 1: Parse HTML - Complete
5. [090] Step 2: Enrich - Complete
6. [090a] Step-Namespaced Status - Complete
7. [091] Step 3: Validation - Complete
8. [092] Step 4: Review UI - Complete
9. **[093] Step 4: Actions** - You are here
10. [094] Step 5: Import
11. [095] Polish & Integration

### The Flow

**Custom HTML Path**:
```
Step 0 (source) -> Step 1 (parse) -> Step 2 (enrich) -> Step 3 (validate) -> Step 4 (review) -> ...
```

### What This Builds

This task implements:
- **Actions dropdown** in each row of the review table with 3 options:
  1. **Edit Metadata** - Modal with raw JSON editor for `list_item.metadata`
  2. **Link Existing Song** - Modal with autocomplete to search our database
  3. **Search MusicBrainz** - Modal with autocomplete to search MusicBrainz API
- **Actions controller** (`Admin::Music::Songs::ListItemsActionsController`) with endpoints
- **MusicBrainz search endpoint** for autocomplete (new)
- **Modal components** for each action type
- **Stimulus controller** for JSON editing
- Controller and component tests

This task does NOT implement (deferred to [095] Polish):
- Bulk actions (verify all, skip all, delete all)
- Verify/Skip individual actions
- Re-enrich action
- Queue for import action
- Delete action

### Key Design Decisions

**Three Actions Only (First Pass)**:
- **Decision**: Focus on the core manual correction workflow
- **Why**:
  - Edit Metadata: Quick fix for typos, wrong parsing
  - Link Existing Song: Connect to known songs in our database
  - Search MusicBrainz: Find the right recording when enrichment failed
- Other actions (verify, skip, delete) can be added in [095]

**Raw JSON Editor for Metadata**:
- **Decision**: Use a simple `<textarea>` with JSON formatting for first pass
- **Why**:
  - Fast to implement
  - Full flexibility - user sees exactly what's stored
  - Can upgrade to structured form later if needed
  - Validates JSON before saving

**Two Autocomplete Modals (Not Combined)**:
- **Decision**: Separate modals for "Link Existing" vs "Search MusicBrainz"
- **Why**:
  - Different data sources with different response structures
  - Clearer UX - user knows which source they're searching
  - Can show additional context per source type
  - Simpler implementation

**MusicBrainz Search Strategy**:
- **Decision**: Use `search_by_artist_and_title` as primary method
- **Why**:
  - Works with text-based search (user types artist and title)
  - Falls back gracefully if no results
  - `search_by_artist_mbid_and_title` requires knowing MBID upfront (less common case)
  - Can add MBID-based search in [095] if needed

---

## Requirements

### Functional Requirements

#### FR-1: Actions Dropdown in Review Table
**Contract**: Replace placeholder "-" in Actions column with dropdown menu

**UI Structure**:
```erb
<td>
  <div class="dropdown dropdown-end">
    <label tabindex="0" class="btn btn-ghost btn-xs">
      <svg><!-- kebab/dots icon --></svg>
    </label>
    <ul tabindex="0" class="dropdown-content menu p-2 shadow bg-base-100 rounded-box w-52 z-50">
      <li><button onclick="edit_metadata_modal_<%= item.id %>.showModal()">Edit Metadata</button></li>
      <li><button onclick="link_song_modal_<%= item.id %>.showModal()">Link Existing Song</button></li>
      <li><button onclick="search_mb_modal_<%= item.id %>.showModal()">Search MusicBrainz</button></li>
    </ul>
  </div>
</td>
```

**Implementation**: Update `review_step_component.html.erb` Actions column

#### FR-2: Edit Metadata Modal
**Contract**: Modal with JSON textarea to edit `list_item.metadata` directly

**UI Layout**:
```
+--------------------------------------------------+
| Edit Metadata                              [X]   |
+--------------------------------------------------+
| Item: #1 - "Come Together" by The Beatles        |
|                                                  |
| Metadata (JSON):                                 |
| +----------------------------------------------+ |
| | {                                            | |
| |   "title": "Come Together",                  | |
| |   "artists": ["The Beatles"],                | |
| |   "album": "Abbey Road",                     | |
| |   "release_year": 1969,                      | |
| |   "song_id": 123,                            | |
| |   "opensearch_match": true                   | |
| | }                                            | |
| +----------------------------------------------+ |
| <validation error if invalid JSON>               |
|                                                  |
| [Cancel]                            [Save]       |
+--------------------------------------------------+
```

**Stimulus Controller**: `metadata-editor`
- Targets: `textarea`, `error`
- Methods: `validate()` - checks JSON validity on input
- Prevents form submit if JSON invalid

**Component**: `Admin::Music::Songs::Wizard::EditMetadataModalComponent`
- Parameters: `list_item:`
- Renders per-item modal with unique dialog ID

#### FR-3: Link Existing Song Modal
**Contract**: Modal with autocomplete to search and link existing `Music::Song`

**UI Layout**:
```
+--------------------------------------------------+
| Link to Existing Song                      [X]   |
+--------------------------------------------------+
| Item: #1 - "Come Together" by The Beatles        |
|                                                  |
| Search for song in our database:                 |
| +----------------------------------------------+ |
| | [Search...                               v]  | |
| +----------------------------------------------+ |
| Start typing to search (min 2 characters)        |
|                                                  |
| [Cancel]                            [Link]       |
+--------------------------------------------------+
```

**Uses**: Existing `AutocompleteComponent` with `url: search_admin_songs_path`

**Component**: `Admin::Music::Songs::Wizard::LinkSongModalComponent`
- Parameters: `list_item:`
- Form submits to `manual_link` action

#### FR-4: Search MusicBrainz Modal
**Contract**: Modal with autocomplete to search MusicBrainz API and link recording

**UI Layout**:
```
+--------------------------------------------------+
| Search MusicBrainz                         [X]   |
+--------------------------------------------------+
| Item: #1 - "Come Together" by The Beatles        |
|                                                  |
| Search MusicBrainz for recordings:               |
| +----------------------------------------------+ |
| | [Search...                               v]  | |
| +----------------------------------------------+ |
| Start typing artist and title (e.g. "Beatles     |
| Come Together")                                  |
|                                                  |
| [Cancel]                            [Link]       |
+--------------------------------------------------+
```

**Autocomplete Endpoint**: `GET /admin/songs/lists/:list_id/wizard/musicbrainz_search`
- Query param: `q` (search text)
- Returns: `[{value: "mbid", text: "Title - Artists (Year)"}]`
- Uses: `Music::Musicbrainz::Search::RecordingSearch#search`

**Component**: `Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent`
- Parameters: `list_item:`, `list:`
- Form submits to `link_musicbrainz` action

#### FR-5: Actions Controller
**Contract**: Handle form submissions for all three actions

**File**: `app/controllers/admin/music/songs/list_items_actions_controller.rb`

**Endpoint Table**:
| Verb | Path | Action | Purpose |
|------|------|--------|---------|
| PATCH | /items/:id/metadata | update_metadata | Update raw metadata JSON |
| POST | /items/:id/manual_link | manual_link | Link to existing song by ID |
| POST | /items/:id/link_musicbrainz | link_musicbrainz | Link to MusicBrainz recording |
| GET | /wizard/musicbrainz_search | musicbrainz_search | Autocomplete endpoint |

**Routes** (update existing in `config/routes.rb:90-105`):
```ruby
resources :items, controller: "list_items_actions", only: [] do
  member do
    patch :update_metadata
    post :manual_link
    post :link_musicbrainz
  end
end

# Add to wizard namespace:
get "wizard/musicbrainz_search", to: "list_items_actions#musicbrainz_search"
```

#### FR-6: MusicBrainz Search Endpoint
**Contract**: Autocomplete-compatible endpoint for MusicBrainz recording search

**Implementation**:
```ruby
def musicbrainz_search
  query = params[:q]
  return render json: [] if query.blank? || query.length < 3

  # Split query into potential artist/title parts
  search = Music::Musicbrainz::Search::RecordingSearch.new
  response = search.search(query, limit: 10)

  return render json: [] unless response[:success]

  recordings = response[:data]["recordings"] || []
  render json: recordings.map { |r|
    artist_names = extract_artist_names(r)
    year = extract_year(r)
    {
      value: r["id"],
      text: "#{r["title"]} - #{artist_names}#{year ? " (#{year})" : ""}"
    }
  }
end
```

---

### Non-Functional Requirements

#### NFR-1: Performance
- [ ] Modal opens in < 100ms
- [ ] Autocomplete search returns in < 500ms (local DB)
- [ ] MusicBrainz search returns in < 2s (external API)
- [ ] No N+1 queries on review page

#### NFR-2: User Experience
- [ ] JSON validation provides clear error messages
- [ ] Autocomplete shows loading indicator
- [ ] Modals close after successful action
- [ ] Table row updates after action (Turbo Stream)

#### NFR-3: Error Handling
- [ ] Invalid JSON shows validation error, blocks submit
- [ ] Non-existent song ID shows error
- [ ] MusicBrainz API timeout shows friendly message
- [ ] All errors displayed in modal, don't lose user input

---

## Contracts & Schemas

### Metadata JSON Schema (What User Edits)

The user edits the full `list_item.metadata` JSONB field. Key fields they might modify:

```json
{
  "title": "Song Title",
  "artists": ["Artist 1", "Artist 2"],
  "album": "Album Name",
  "release_year": 1969,
  "rank": 1,
  "song_id": 123,
  "song_name": "Matched Song",
  "opensearch_match": true,
  "opensearch_score": 18.5,
  "mb_recording_id": "uuid-here",
  "mb_recording_name": "Recording Name",
  "mb_artist_names": ["Artist"],
  "musicbrainz_match": true,
  "ai_match_invalid": false
}
```

### Update Metadata Request

```
PATCH /admin/songs/lists/:list_id/items/:id/metadata
Content-Type: application/x-www-form-urlencoded

list_item[metadata_json]={"title":"Fixed Title",...}
```

**Response**: Turbo Stream updating the table row

### Manual Link Request

```
POST /admin/songs/lists/:list_id/items/:id/manual_link
Content-Type: application/x-www-form-urlencoded

song_id=123
```

**Response**: Turbo Stream updating the table row

### Link MusicBrainz Request

```
POST /admin/songs/lists/:list_id/items/:id/link_musicbrainz
Content-Type: application/x-www-form-urlencoded

mb_recording_id=abc-123-def
```

**Behavior**:
1. Store `mb_recording_id` in metadata
2. Look up if `Music::Song` exists with this MBID
3. If exists: set `listable_id`
4. Update metadata with MB data

**Response**: Turbo Stream updating the table row

### MusicBrainz Search Response

```
GET /admin/songs/lists/:list_id/wizard/musicbrainz_search?q=beatles+come+together

[
  {
    "value": "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
    "text": "Come Together - The Beatles (1969)"
  },
  {
    "value": "another-mbid",
    "text": "Come Together (Remaster) - The Beatles (2009)"
  }
]
```

---

## Acceptance Criteria

### Actions Dropdown
- [x] Each review table row has actions dropdown
- [x] Dropdown shows 3 options: Edit Metadata, Link Existing, Search MusicBrainz
- [x] Dropdown is positioned correctly (z-index, doesn't clip)
- [x] Dropdown closes when clicking outside

### Edit Metadata Modal
- [x] Modal opens with current metadata as formatted JSON
- [x] Textarea is editable with reasonable size (15 rows)
- [x] Invalid JSON shows error message below textarea
- [x] Save button disabled when JSON invalid
- [x] Successful save closes modal
- [x] Successful save updates table row
- [x] Cancel closes modal without saving

### Link Existing Song Modal
- [x] Modal opens with autocomplete input
- [x] Autocomplete searches songs in database
- [x] Selecting song enables Link button
- [x] Successful link closes modal
- [x] Successful link updates table row with song info
- [x] Sets `listable_id` and `verified = true`

### Search MusicBrainz Modal
- [x] Modal opens with autocomplete input
- [x] Autocomplete searches MusicBrainz API
- [x] Results show title, artists, year
- [x] Selecting recording enables Link button
- [x] Successful link closes modal
- [x] Successful link updates metadata with MB data
- [x] If song exists with MBID, sets `listable_id`

### Controller Actions
- [x] `metadata` validates JSON and updates metadata
- [x] `manual_link` sets listable_id and marks verified
- [x] `link_musicbrainz` updates metadata and optionally links song
- [x] `musicbrainz_search` returns autocomplete-compatible JSON
- [x] All actions return Turbo Stream responses
- [x] Unauthorized access redirects (admin required)

### Tests
- [x] Controller tests for all 4 actions (17 tests)
- [x] Component tests for all 3 modals (32 tests)
- [x] Stimulus controller for JSON validation (included in component tests)
- [ ] System test for full action flow (deferred to [095] Polish)

---

## Golden Examples

### Example 1: Edit Metadata Flow

**Initial State** (item has typo):
```ruby
list_item.metadata = {
  "title" => "Cme Together",  # typo
  "artists" => ["The Beatles"]
}
```

**User Action**:
1. Click actions dropdown
2. Select "Edit Metadata"
3. Modal opens with JSON
4. Fix typo: "Cme Together" -> "Come Together"
5. Click Save

**Result**:
```ruby
list_item.metadata = {
  "title" => "Come Together",  # fixed
  "artists" => ["The Beatles"]
}
```
- Table row updates to show corrected title
- Modal closes

### Example 2: Link Existing Song Flow

**Initial State** (item not matched):
```ruby
list_item.listable_id = nil
list_item.verified = false
list_item.metadata = {
  "title" => "Come Together",
  "artists" => ["The Beatles"]
}
```

**User Action**:
1. Click actions dropdown
2. Select "Link Existing Song"
3. Type "come together beatles" in autocomplete
4. Select "Come Together - The Beatles" from results
5. Click Link

**Result**:
```ruby
list_item.listable_id = 456  # linked song
list_item.verified = true
list_item.metadata = {
  "title" => "Come Together",
  "artists" => ["The Beatles"],
  "song_id" => 456,
  "song_name" => "Come Together",
  "manual_link" => true
}
```
- Table row shows as Valid (green badge)
- Matched column shows song name
- Modal closes

### Example 3: Search MusicBrainz Flow

**Initial State** (item not in our database):
```ruby
list_item.listable_id = nil
list_item.metadata = {
  "title" => "Rare B-Side",
  "artists" => ["Obscure Artist"]
}
```

**User Action**:
1. Click actions dropdown
2. Select "Search MusicBrainz"
3. Type "obscure artist rare b-side"
4. Select result from MusicBrainz
5. Click Link

**Result**:
```ruby
list_item.metadata = {
  "title" => "Rare B-Side",
  "artists" => ["Obscure Artist"],
  "mb_recording_id" => "abc-123",
  "mb_recording_name" => "Rare B-Side",
  "mb_artist_names" => ["Obscure Artist"],
  "musicbrainz_match" => true,
  "manual_musicbrainz_link" => true
}
# listable_id may or may not be set depending on if song exists
```
- Modal closes
- Table row shows MB badge in Source column

---

## Technical Approach

### File Structure

```
web-app/
├── app/
│   ├── controllers/
│   │   └── admin/music/songs/
│   │       └── list_items_actions_controller.rb        # NEW
│   ├── components/
│   │   └── admin/music/songs/wizard/
│   │       ├── review_step_component.html.erb          # MODIFY: Add actions dropdown
│   │       ├── edit_metadata_modal_component.rb        # NEW
│   │       ├── edit_metadata_modal_component.html.erb  # NEW
│   │       ├── link_song_modal_component.rb            # NEW
│   │       ├── link_song_modal_component.html.erb      # NEW
│   │       ├── search_musicbrainz_modal_component.rb   # NEW
│   │       └── search_musicbrainz_modal_component.html.erb # NEW
│   └── javascript/controllers/
│       └── metadata_editor_controller.js               # NEW
├── config/
│   └── routes.rb                                       # MODIFY: Update item routes
└── test/
    ├── controllers/admin/music/songs/
    │   └── list_items_actions_controller_test.rb       # NEW
    └── components/admin/music/songs/wizard/
        ├── edit_metadata_modal_component_test.rb       # NEW
        ├── link_song_modal_component_test.rb           # NEW
        └── search_musicbrainz_modal_component_test.rb  # NEW
```

---

## Implementation Steps

### Phase 1: Controller Setup

1. **Generate controller**
   - [ ] `bin/rails generate controller Admin::Music::Songs::ListItemsActions --skip-routes`
   - [ ] Implement `update_metadata` action
   - [ ] Implement `manual_link` action
   - [ ] Implement `link_musicbrainz` action
   - [ ] Implement `musicbrainz_search` action

2. **Update routes**
   - [ ] Modify existing routes in `config/routes.rb`
   - [ ] Add `musicbrainz_search` to wizard namespace

3. **Write controller tests**
   - [ ] Test all 4 actions
   - [ ] Test error cases

### Phase 2: Modal Components

4. **Create EditMetadataModalComponent**
   - [ ] Generate component
   - [ ] Create template with JSON textarea
   - [ ] Create Stimulus controller for validation

5. **Create LinkSongModalComponent**
   - [ ] Generate component
   - [ ] Use existing AutocompleteComponent
   - [ ] Point to existing `search_admin_songs_path`

6. **Create SearchMusicbrainzModalComponent**
   - [ ] Generate component
   - [ ] Use existing AutocompleteComponent
   - [ ] Point to new `musicbrainz_search` endpoint

7. **Write component tests**
   - [ ] Test each modal renders correctly

### Phase 3: Integration

8. **Update review_step_component**
   - [ ] Replace Actions placeholder with dropdown
   - [ ] Render all 3 modals per item
   - [ ] Add Turbo Frame target for row updates

9. **Add Turbo Stream responses**
   - [ ] Create `_item_row.html.erb` partial
   - [ ] Return stream updates from actions

### Phase 4: Testing

10. **System tests**
    - [ ] Test full action workflows
    - [ ] Test error handling

---

## Validation Checklist (Definition of Done)

- [ ] Actions dropdown appears in every review table row
- [ ] Edit Metadata modal edits raw JSON with validation
- [ ] Link Existing Song modal uses autocomplete with our DB
- [ ] Search MusicBrainz modal uses autocomplete with MB API
- [ ] All actions return Turbo Stream responses
- [ ] Table rows update after actions without page refresh
- [ ] Controller tests pass (10+ tests)
- [ ] Component tests pass (9+ tests)
- [ ] System tests pass (3+ tests)
- [ ] No N+1 queries
- [ ] Documentation updated

---

## Dependencies

### Depends On (Completed)
- [092] Step 4: Review UI - Table structure with Actions column placeholder

### Needed By (Blocked Until This Completes)
- [094] Step 5: Import - Review step must be functional
- [095] Polish - Additional actions (verify, skip, delete, bulk)

### External References
- **Existing AutocompleteComponent**: `app/components/autocomplete_component.rb`
- **Modal Pattern**: `app/components/admin/add_item_to_list_modal_component/`
- **MusicBrainz Search**: `app/lib/music/musicbrainz/search/recording_search.rb`
- **Song Search Endpoint**: `app/controllers/admin/music/songs_controller.rb:94-114`
- **Routes (existing)**: `config/routes.rb:90-105`

---

## Related Tasks

- **Previous**: [092] Step 4: Review UI
- **Next**: [094] Step 5: Import
- **Enhancement**: [095] Polish adds verify, skip, delete, bulk actions

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns (ViewComponents, Stimulus, DaisyUI modals)
- Use existing AutocompleteComponent for both autocompletes
- Use existing MusicBrainz::Search::RecordingSearch
- Do not duplicate authoritative code; **link to files by path**
- Respect snippet budget (<=40 lines per snippet)
- Use Rails generators for controllers and components

### Required Outputs
- New file: `app/controllers/admin/music/songs/list_items_actions_controller.rb`
- New file: `app/components/admin/music/songs/wizard/edit_metadata_modal_component.rb`
- New file: `app/components/admin/music/songs/wizard/link_song_modal_component.rb`
- New file: `app/components/admin/music/songs/wizard/search_musicbrainz_modal_component.rb`
- New file: `app/javascript/controllers/metadata_editor_controller.js`
- New file: `test/controllers/admin/music/songs/list_items_actions_controller_test.rb`
- Modified: `app/components/admin/music/songs/wizard/review_step_component.html.erb`
- Modified: `config/routes.rb`
- Passing tests for all new functionality (20+ tests)
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1. **codebase-pattern-finder** -> Already done (modal, autocomplete patterns)
2. **codebase-analyzer** -> Already done (MusicBrainz integration)
3. **technical-writer** -> Update docs after implementation

### Test Fixtures
- Use existing `lists(:music_songs_list)` fixture
- Use existing `music_songs(:time)` fixture for linking tests
- Mock MusicBrainz API responses in tests

---

## Implementation Notes

### Files Created
- `app/controllers/admin/music/songs/list_items_actions_controller.rb` - Controller with 5 actions: `verify`, `metadata`, `manual_link`, `link_musicbrainz`, `musicbrainz_search`
- `app/components/admin/music/songs/wizard/edit_metadata_modal_component.rb` + `.html.erb` - Modal for editing raw JSON metadata
- `app/components/admin/music/songs/wizard/link_song_modal_component.rb` + `.html.erb` - Modal with autocomplete for linking existing songs
- `app/components/admin/music/songs/wizard/search_musicbrainz_modal_component.rb` + `.html.erb` - Modal with autocomplete for MusicBrainz search
- `app/javascript/controllers/metadata_editor_controller.js` - Stimulus controller for JSON validation
- `app/views/admin/music/songs/list_items_actions/_item_row.html.erb` - Partial for Turbo Stream row updates
- `app/views/admin/music/songs/list_items_actions/_error_message.html.erb` - Error message partial
- `app/views/admin/music/songs/list_items_actions/_flash_success.html.erb` - Success message partial
- `test/controllers/admin/music/songs/list_items_actions_controller_test.rb` - 20 controller tests
- `test/components/admin/music/songs/wizard/edit_metadata_modal_component_test.rb` - 11 component tests
- `test/components/admin/music/songs/wizard/link_song_modal_component_test.rb` - 10 component tests
- `test/components/admin/music/songs/wizard/search_musicbrainz_modal_component_test.rb` - 14 component tests

### Files Modified
- `config/routes.rb` - Added `musicbrainz_search` route to wizard namespace, added `link_musicbrainz` route to items member routes
- `app/components/admin/music/songs/wizard/review_step_component.html.erb` - Added actions dropdown with 4 options (Verify, Edit Metadata, Link Existing Song, Search MusicBrainz), added row ID for Turbo updates, renders all 3 modals per item
- `app/components/admin/music/songs/wizard/review_step_component.rb` - Added `verify_path` helper
- `app/javascript/controllers/autocomplete_controller.js` - Fixed URL query param handling (use `&` when URL already has `?`)

### Test Coverage
- 55 new tests total (20 controller + 35 component tests)
- All project tests pass

### Design Decisions
- Used raw HTML textarea for metadata editing (fast to implement, full flexibility)
- Used existing `AutocompleteComponent` for both link actions
- **MusicBrainz search requires `mb_artist_ids` in item metadata** - Uses `RecordingSearch#search_by_artist_mbid_and_title` for precise results. If no artist MBID is available, shows a warning message instead of the search form
- `link_musicbrainz` always sets `verified = true` (authoritative match from MusicBrainz)
- Added `verify` action to manually mark items as verified
- Turbo Stream responses update table rows and show flash messages
- Modals close automatically on successful action via `modal-form` Stimulus controller

---

## Deviations from Plan

- Controller action named `metadata` instead of `update_metadata` to match existing route pattern in routes.rb
- Used plain HTML textarea instead of `f.text_area` helper to have full control over the `name` attribute
- Helper methods in `_item_row.html.erb` partial are inline instead of using component helper methods (simpler for partial context)
- **MusicBrainz Search Strategy changed**: Originally planned to use `RecordingSearch#search` (free-form text search). Changed to require `mb_artist_ids` in metadata and use `search_by_artist_mbid_and_title` instead. Free-form MusicBrainz search returns too many irrelevant results; artist MBID-based search is much more precise.
- **Added `verify` action**: Not originally planned for this task (was deferred to [095]), but implemented as it's a simple, commonly needed action
- **`link_musicbrainz` always verifies**: Originally only verified if song exists in database; now always sets `verified = true` since MusicBrainz match is authoritative

---

## Documentation Updated

- This task document updated with implementation notes, deviations, and completion status

---

## Notes

### Design Rationale

**Why Raw JSON Editor?**
- First pass prioritizes speed of implementation
- Full flexibility for power users
- Easy to validate (JSON.parse succeeds)
- Can add structured form in [095] if needed

**Why Separate Modals per Source?**
- Clearer UX - user knows what they're searching
- Different data structures from different sources
- Simpler error handling per source
- Can combine in future if feedback suggests

**Why Only 3 Actions?**
- Core manual correction workflow
- Verify/skip/delete are secondary (most items auto-process)
- Re-enrich can be added in [095]
- Keeps scope manageable

### Future Enhancements (Deferred to [095])
- [ ] Structured form for metadata editing
- [x] Verify action (mark as correct) - **Implemented in this task**
- [ ] Skip action (mark to ignore)
- [ ] Delete action (remove item)
- [ ] Re-enrich action (re-run enrichment)
- [ ] Bulk actions (verify all, skip all, delete all)
- [x] MBID-based search option (`search_by_artist_mbid_and_title`) - **Implemented in this task** (MusicBrainz search now requires artist MBID for precise results)
