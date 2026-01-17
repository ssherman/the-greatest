# 119 - Admin Import Artist from MusicBrainz

## Status
- **Status**: Not Started
- **Priority**: Medium
- **Created**: 2026-01-16
- **Started**:
- **Completed**:
- **Developer**:

## Overview
Add ability to import an artist from MusicBrainz directly from the admin artists index page. User clicks "Import From MusicBrainz" button, searches for an artist via autocomplete, and imports them using the existing `DataImporters::Music::Artist::Importer`.

**Non-goals**:
- Bulk import (single artist at a time)
- Modifying the existing importer behavior

## Context & Links
- **Depends on**: Spec 120 (Refactor MusicBrainz Search Controller) - implement first
- Related features: List Wizard (`docs/features/list-wizard.md`) - uses same MusicBrainz autocomplete pattern
- Data Importer: `docs/features/data_importers.md`
- Existing admin patterns: `app/views/admin/music/artists/show.html.erb` (modal examples)

### Source Files (authoritative)
- `app/controllers/admin/music/artists_controller.rb`
- `app/views/admin/music/artists/index.html.erb`
- `app/lib/data_importers/music/artist/importer.rb`
- `app/lib/data_importers/music/artist/finder.rb`
- `app/controllers/concerns/list_items_actions.rb` (MusicBrainz search pattern)

## Interfaces & Contracts

### Endpoints

| Verb | Path | Purpose | Params/Body | Auth |
|------|------|---------|-------------|------|
| GET | `/admin/music/musicbrainz/artists` | Autocomplete JSON (from Spec 120) | `q` (query string, min 2 chars) | admin |
| POST | `/admin/artists/import_from_musicbrainz` | Import artist by MusicBrainz ID | `musicbrainz_id` (UUID) | admin |

> Source of truth: `config/routes.rb`

### Schemas (JSON)

**GET /admin/artists/musicbrainz_search Response:**
```json
[
  {
    "value": "83d91898-7763-47d7-b03b-b92132375c47",
    "text": "Pink Floyd (Group from United Kingdom)"
  }
]
```

**POST /admin/artists/import_from_musicbrainz:**
- Success (new artist): Redirect to `admin_artist_path(artist)` with notice "Artist imported successfully"
- Success (existing): Redirect to `admin_artist_path(existing_artist)` with notice "Artist already exists"
- Failure: Redirect to `admin_artists_path` with alert containing error message

### Behaviors (pre/postconditions)

**Preconditions:**
- User is authenticated admin
- MusicBrainz ID is valid UUID format

**Postconditions/effects:**
- New artist created in database with MusicBrainz data (name, kind, country, identifiers, categories)
- Or existing artist found via MusicBrainz ID lookup

**Edge cases & failure modes:**
- Query < 2 chars: Return empty array `[]`
- MusicBrainz API timeout: Return empty array (graceful degradation)
- Invalid MusicBrainz ID format: Redirect with error flash
- Artist already exists (has matching MusicBrainz ID): Redirect to existing artist with info flash
- Importer failure: Redirect with error flash containing importer errors

### Non-Functionals
- MusicBrainz search should complete in < 2 seconds (API dependent)
- No N+1 queries on import
- Autocomplete debounced at 300ms (handled by AutocompleteComponent)

## Acceptance Criteria

- [ ] "Import From MusicBrainz" button appears next to "New Artist" button on index page
- [ ] Clicking button opens modal with autocomplete search field
- [ ] Autocomplete searches MusicBrainz API as user types (min 2 chars)
- [ ] Autocomplete displays artist name with type and location: "Pink Floyd (Group from United Kingdom)"
- [ ] Selecting artist and clicking "Import" calls importer with MusicBrainz ID
- [ ] Successful import redirects to new artist's show page with success flash
- [ ] If artist already exists (matching MusicBrainz ID), redirects to existing artist with info flash
- [ ] Import errors display as flash alerts on index page
- [ ] Modal can be dismissed via Cancel button or clicking outside

### Golden Examples

**Example 1: New Artist Import**
```text
Input: User searches "Pink Floyd", selects result, clicks Import
Expected:
  - Importer.call(musicbrainz_id: "83d91898-7763-47d7-b03b-b92132375c47")
  - New Music::Artist created with name, kind, country, identifiers
  - Redirect to /admin/artists/123 with flash "Artist imported successfully"
```

**Example 2: Existing Artist**
```text
Input: User searches "The Beatles", selects result, clicks Import
  (The Beatles already exists in database with this MusicBrainz ID)
Expected:
  - Finder detects existing artist via Identifier lookup
  - Redirect to /admin/artists/456 with flash "Artist already exists"
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture
- Respect snippet budget (≤40 lines)
- Do not duplicate authoritative code; **link to file paths**
- Reuse existing `AutocompleteComponent` and MusicBrainz search pattern from `ListItemsActions`

### Required Outputs
- Updated files (paths listed in "Key Files Touched")
- Passing tests demonstrating Acceptance Criteria
- Updated: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder → Verify modal pattern from show.html.erb, MusicBrainz search from ListItemsActions
2) codebase-analyzer → Confirm route structure for collection-level actions
3) technical-writer → Update docs if needed

### Test Seed / Fixtures
- Use existing artist fixtures if available
- Mock MusicBrainz API responses in controller tests

---

## Implementation Notes (living)

### Approach

**1. Add Routes**
Add to `config/routes.rb` inside `resources :artists` block:
```ruby
collection do
  post :import_from_musicbrainz
end
```

Note: The MusicBrainz search endpoint is provided by Spec 120's `MusicbrainzSearchController`.

**2. Controller Action**
Add to `Admin::Music::ArtistsController`:

`import_from_musicbrainz` - New action:
- Validate MusicBrainz ID format (UUID)
- Call `DataImporters::Music::Artist::Importer.call(musicbrainz_id: params[:musicbrainz_id])`
- Check if result.item was already persisted before import (existing artist case)
- Redirect appropriately with flash message

**3. View Updates**
Add to `app/views/admin/music/artists/index.html.erb`:
- Button next to "New Artist" that opens modal
- Modal dialog with AutocompleteComponent pointing to `admin_musicbrainz_artists_path`
- Follow pattern from merge-artist-modal in show.html.erb

### Key Files Touched (paths only)
- `config/routes.rb` (add `import_from_musicbrainz` collection route)
- `app/controllers/admin/music/artists_controller.rb` (add `import_from_musicbrainz` action)
- `app/views/admin/music/artists/index.html.erb` (add button + modal)
- `test/controllers/admin/music/artists_controller_test.rb`

### Reference: Modal Pattern (≤40 lines, non-authoritative)
```erb
<!-- Pattern to follow from show.html.erb -->
<dialog id="import-musicbrainz-modal" class="modal">
  <div class="modal-box max-w-2xl">
    <h3 class="font-bold text-lg">Import Artist from MusicBrainz</h3>
    <%= form_with url: import_from_musicbrainz_admin_artists_path, method: :post do |f| %>
      <div class="form-control">
        <%= render AutocompleteComponent.new(
          name: "musicbrainz_id",
          url: admin_musicbrainz_artists_path,
          placeholder: "Search MusicBrainz for artist...",
          required: true
        ) %>
      </div>
      <div class="modal-action">
        <button type="button" class="btn" onclick="...close()">Cancel</button>
        <%= f.submit "Import", class: "btn btn-primary" %>
      </div>
    <% end %>
  </div>
</dialog>
```

### Challenges & Resolutions
- None anticipated; straightforward pattern reuse

### Deviations From Plan
- (none yet)

## Acceptance Results
- Date, verifier, artifacts (screenshots/links):

## Future Improvements
- Bulk import from MusicBrainz search results
- Import artist with albums in one action

## Related PRs
-

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs (if any new classes created)
