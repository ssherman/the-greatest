# 104 - Albums Wizard Review Step & Actions

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-12-27
- **Started**:
- **Completed**:
- **Developer**:

## Overview
Implement the review step for the Albums List Wizard. This step provides a UI for manual verification of album matches, with actions to edit metadata, link to existing albums, search MusicBrainz release groups, and search/change artists.

**Goal**: Enable manual review and correction of album matches before import.
**Scope**: Review step component, ListItemsActionsController, modal components, autocomplete endpoints.
**Non-goals**: Import functionality (handled in spec 105).

## Context & Links
- Prerequisite: spec 100, 101, 102, 103
- Songs review reference: `app/components/admin/music/songs/wizard/review_step_component.rb`
- Songs actions controller: `app/controllers/admin/music/songs/list_items_actions_controller.rb`
- Existing album autocomplete: `app/lib/search/music/search/album_autocomplete.rb`
- ReleaseGroupSearch (exists): `app/lib/music/musicbrainz/search/release_group_search.rb`

## Interfaces & Contracts

### Routes (add to albums wizard routes)

| Verb | Path | Action | Purpose |
|------|------|--------|---------|
| GET | `.../wizard/musicbrainz_release_search` | musicbrainz_release_search | Autocomplete for MB releases |
| GET | `.../wizard/musicbrainz_artist_search` | musicbrainz_artist_search | Autocomplete for MB artists |
| GET | `.../items/:id/modal/:modal_type` | modal | Load modal content on-demand |
| POST | `.../items/:id/verify` | verify | Mark item as verified |
| PATCH | `.../items/:id/metadata` | metadata | Update item metadata JSON |
| POST | `.../items/:id/manual_link` | manual_link | Link to existing album |
| POST | `.../items/:id/link_musicbrainz_release` | link_musicbrainz_release | Link to MB release group |
| POST | `.../items/:id/link_musicbrainz_artist` | link_musicbrainz_artist | Change artist match |

### Controller: Admin::Music::Albums::ListItemsActionsController

```ruby
# app/controllers/admin/music/albums/list_items_actions_controller.rb
class Admin::Music::Albums::ListItemsActionsController < Admin::Music::BaseController
  before_action :set_list
  before_action :set_item, except: [:musicbrainz_release_search, :musicbrainz_artist_search]

  VALID_MODAL_TYPES = %w[edit_metadata link_album search_musicbrainz_releases search_musicbrainz_artists].freeze

  def modal
    # Load modal content based on modal_type param
  end

  def verify
    # Mark item as verified, clear ai_match_invalid
  end

  def metadata
    # Update item metadata from JSON input
  end

  def manual_link
    # Link item to existing Music::Album by ID
  end

  def link_musicbrainz_release
    # Look up release group, update metadata, optionally link to existing album
  end

  def link_musicbrainz_artist
    # Change artist match, clear stale release data
  end

  def musicbrainz_release_search
    # Autocomplete endpoint using ReleaseGroupSearch
  end

  def musicbrainz_artist_search
    # Autocomplete endpoint using ArtistSearch (can reuse songs implementation)
  end

  private

  def set_list
    @list = Music::Albums::List.find(params[:list_id])
  end

  def set_item
    @item = @list.list_items.includes(listable: :artists).find(params[:id])
  end
end
```

### Step Component: ReviewStepComponent

```ruby
# app/components/admin/music/albums/wizard/review_step_component.rb
class Admin::Music::Albums::Wizard::ReviewStepComponent < ViewComponent::Base
  def initialize(list:, items: [], total_count: 0, valid_count: 0, invalid_count: 0, missing_count: 0)
    @list = list
    @items = items
    @total_count = total_count
    @valid_count = valid_count
    @invalid_count = invalid_count
    @missing_count = missing_count
  end

  def item_status(item)
    return "valid" if item.verified?
    return "invalid" if item.metadata["ai_match_invalid"]
    "missing"
  end
end
```

Uses CSS-based filtering via `review_filter_controller.js` (existing, no changes needed).

### Modal Components

| Component | Purpose |
|-----------|---------|
| `SharedModalComponent` | Container for on-demand modal loading |
| `EditMetadataModalComponent` | JSON editor for item metadata |
| `LinkAlbumModalComponent` | Search and link to existing album |
| `SearchMusicbrainzModalComponent` | Search MB release groups |

Note: SearchMusicbrainzArtists can potentially share component with songs.

```ruby
# app/components/admin/music/albums/wizard/link_album_modal_component.rb
class Admin::Music::Albums::Wizard::LinkAlbumModalComponent < ViewComponent::Base
  def initialize(list:, item:)
    @list = list
    @item = item
  end

  def autocomplete_url
    search_admin_albums_path  # Existing admin albums search endpoint
  end
end
```

### Autocomplete Response Schemas

**MusicBrainz Release Group Search:**
```json
[
  {
    "value": "a1b2c3d4-e5f6-...",
    "text": "The Dark Side of the Moon - Pink Floyd (1973)"
  }
]
```

**Local Album Search:**
```json
[
  {
    "value": "123",
    "text": "The Dark Side of the Moon - Pink Floyd"
  }
]
```

### View Partials (Turbo Stream targets)

| Partial | Purpose |
|---------|---------|
| `_item_row.html.erb` | Single row in review table |
| `_review_stats.html.erb` | Stats cards (valid/invalid/missing counts) |
| `_flash_success.html.erb` | Success message toast |
| `_error_message.html.erb` | Error message toast |

### Behaviors (pre/postconditions)

**Preconditions:**
- Validate step completed
- Items have status (verified, ai_match_invalid, or neither)

**Postconditions:**
- Verified items ready for import
- Invalid items corrected or skipped
- Stats update in real-time via Turbo Streams

**Edge cases:**
- No items to review: show empty state with option to go back
- All items already verified: show success message
- MusicBrainz search returns no results: show "No results" message

### Non-Functionals
- CSS-based filtering for O(1) performance with 1000+ items
- Turbo Stream updates for individual row changes
- Stats cards update without page reload
- Autocomplete response < 500ms

## Acceptance Criteria
- [ ] Review step displays all items in filterable table
- [ ] Filter buttons work (All, Valid, Invalid, Missing)
- [ ] Stats cards show correct counts
- [ ] Dropdown actions menu per row
- [ ] "Verify" action marks item verified
- [ ] "Edit Metadata" opens modal with JSON editor
- [ ] "Link Existing Album" opens modal with album autocomplete
- [ ] "Search MusicBrainz Releases" opens modal with release search
- [ ] "Search MusicBrainz Artists" opens modal with artist search
- [ ] All actions update row and stats via Turbo Stream
- [ ] Next button disabled until at least one valid item exists

### Golden Examples

**Turbo Stream response for verify action:**
```ruby
respond_to do |format|
  format.turbo_stream do
    render turbo_stream: [
      turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: { item: @item, list: @list }),
      turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: { list: @list }),
      turbo_stream.prepend("flash_messages", partial: "flash_success", locals: { message: "Item verified" })
    ]
  end
end
```

---

## Agent Hand-Off

### Constraints
- Follow songs ListItemsActionsController pattern closely
- Reuse existing Stimulus controllers (review_filter, autocomplete)
- Use ReleaseGroupSearch instead of RecordingSearch
- Album autocomplete already exists (AlbumAutocomplete)

### Required Outputs
- `app/controllers/admin/music/albums/list_items_actions_controller.rb`
- `app/components/admin/music/albums/wizard/review_step_component.rb`
- `app/components/admin/music/albums/wizard/review_step_component.html.erb`
- `app/components/admin/music/albums/wizard/shared_modal_component.rb` (or reuse songs version)
- `app/components/admin/music/albums/wizard/edit_metadata_modal_component.rb`
- `app/components/admin/music/albums/wizard/link_album_modal_component.rb`
- `app/components/admin/music/albums/wizard/search_musicbrainz_modal_component.rb`
- `app/views/admin/music/albums/list_items_actions/_item_row.html.erb`
- `app/views/admin/music/albums/list_items_actions/_review_stats.html.erb`
- `app/views/admin/music/albums/list_items_actions/modals/*.html.erb`
- Test files for controller and components

### Sub-Agent Plan
1) codebase-analyzer → Review songs ListItemsActionsController in detail
2) codebase-pattern-finder → Find modal component patterns
3) codebase-analyzer → Verify ReleaseGroupSearch API matches RecordingSearch

### Test Seed / Fixtures
- ListItems with various statuses (verified, invalid, missing)
- Existing Music::Album records for linking tests

---

## Implementation Notes (living)
- Approach taken:
- Important decisions:

### Key Files Touched (paths only)
- `config/routes.rb`
- `app/controllers/admin/music/albums/list_items_actions_controller.rb`
- `app/components/admin/music/albums/wizard/review_step_component.rb`
- `app/components/admin/music/albums/wizard/link_album_modal_component.rb`
- `app/components/admin/music/albums/wizard/search_musicbrainz_modal_component.rb`
- `app/views/admin/music/albums/list_items_actions/*.html.erb`
- `app/helpers/admin/music/albums/list_wizard_helper.rb`

### Challenges & Resolutions
-

### Deviations From Plan
-

## Acceptance Results
- Date, verifier, artifacts:

## Future Improvements
- Consider extracting base ListItemsActionsController concern
- Consider shared modal components between songs and albums
- Could add bulk verify/reject actions

## Related PRs
-

## Documentation Updated
- [ ] Class docs for new files
- [ ] `docs/controllers/admin/music/albums/list_items_actions_controller.md`
