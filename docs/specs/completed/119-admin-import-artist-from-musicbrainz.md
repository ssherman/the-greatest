# 119 - Admin Import Artist from MusicBrainz

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-16
- **Started**: 2026-01-16
- **Completed**: 2026-01-16
- **Developer**: Claude

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
- Missing param: Redirect to `admin_artists_path` with alert "Please select an artist from MusicBrainz"

### Behaviors (pre/postconditions)

**Preconditions:**
- User is authenticated admin
- MusicBrainz ID is provided (validated server-side)

**Postconditions/effects:**
- New artist created in database with MusicBrainz data (name, kind, country, identifiers, categories)
- Or existing artist found via MusicBrainz ID lookup

**Edge cases & failure modes:**
- Query < 2 chars: Return empty array `[]`
- MusicBrainz API timeout: Return empty array (graceful degradation)
- Missing MusicBrainz ID: Redirect with error flash
- Artist already exists (has matching MusicBrainz ID): Redirect to existing artist with info flash
- Importer failure: Redirect with error flash containing importer errors

### Non-Functionals
- MusicBrainz search should complete in < 2 seconds (API dependent)
- No N+1 queries on import
- Autocomplete debounced at 300ms (handled by AutocompleteComponent)

## Acceptance Criteria

- [x] "Import From MusicBrainz" button appears next to "New Artist" button on index page
- [x] Clicking button opens modal with autocomplete search field
- [x] Autocomplete searches MusicBrainz API as user types (min 2 chars)
- [x] Autocomplete displays artist name with type and location: "Pink Floyd (Group from United Kingdom)"
- [x] Selecting artist and clicking "Import" calls importer with MusicBrainz ID
- [x] Successful import redirects to new artist's show page with success flash
- [x] If artist already exists (matching MusicBrainz ID), redirects to existing artist with info flash
- [x] Import errors display as flash alerts on index page
- [x] Modal can be dismissed via Cancel button or clicking outside

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
Added to `config/routes.rb` inside `resources :artists` collection block (line 161):
```ruby
collection do
  post :import_from_musicbrainz
  # ... existing routes
end
```

**2. Controller Action**
Added `import_from_musicbrainz` action to `Admin::Music::ArtistsController` (lines 102-121):
- Validates `musicbrainz_id` presence (server-side validation)
- Calls `DataImporters::Music::Artist::Importer.call(musicbrainz_id: params[:musicbrainz_id])`
- Detects existing vs new artist via `result.provider_results.empty?` (finder returns early with empty provider_results when artist exists)
- Redirects appropriately with flash message

**3. View Updates**
Added to `app/views/admin/music/artists/index.html.erb`:
- "Import From MusicBrainz" button next to "New Artist" (lines 11-15)
- Modal dialog with AutocompleteComponent (lines 58-98)
- Follows merge-artist-modal pattern from show.html.erb
- Uses `modal-form` Stimulus controller for auto-close on success

### Key Files Touched (paths only)
- `config/routes.rb:161` (add `import_from_musicbrainz` collection route)
- `app/controllers/admin/music/artists_controller.rb:102-121` (add `import_from_musicbrainz` action)
- `app/views/admin/music/artists/index.html.erb:11-15,58-98` (add button + modal)
- `test/controllers/admin/music/artists_controller_test.rb:455-554` (add 5 tests)

### Key Decisions
1. **Direct controller action** instead of index_action pattern - simpler since importer already has its own result handling
2. **No UUID validation** - autocomplete only returns valid MusicBrainz IDs from API
3. **Server-side presence validation** - added to prevent 500 error if form is bypassed
4. **Detect existing via provider_results** - `result.provider_results.empty?` indicates finder returned early

### Challenges & Resolutions
- None; straightforward pattern reuse as anticipated

### Deviations From Plan
- Removed UUID format validation from controller - unnecessary since autocomplete returns valid MusicBrainz IDs
- Added server-side presence validation for `musicbrainz_id` parameter (not in original spec)

## Acceptance Results
- **Date**: 2026-01-16
- **Verifier**: Claude
- **Tests**: 45 tests pass (5 new tests for import functionality)
- **Test file**: `test/controllers/admin/music/artists_controller_test.rb`

## Future Improvements
- Bulk import from MusicBrainz search results
- Import artist with albums in one action

## Related PRs
- (pending)

## Documentation Updated
- [x] Controller documentation: `docs/controllers/admin/music/artists_controller.md`
- [x] Spec file moved to `docs/specs/completed/`
