# MusicBrainz URL Link Action for Music List Wizard

## Status
- **Status**: Complete
- **Priority**: Medium
- **Created**: 2026-03-03
- **Started**: 2026-03-04
- **Completed**: 2026-03-04
- **Developer**: AI Agent

## Overview

Add a "Link by MusicBrainz URL" action to the music list wizard review step for both songs and albums. Users paste a MusicBrainz URL to directly link a list item to a MusicBrainz entity, bypassing the artist-scoped search workflow. This mirrors the existing "Link by IGDB ID" action in the games wizard.

- **Albums**: Accept `https://musicbrainz.org/release-group/{uuid}` URLs → maps to `mb_release_group_id`
- **Songs**: Accept `https://musicbrainz.org/recording/{uuid}` URLs → maps to `mb_recording_id`

**Non-goals**: No autocomplete/search UI needed (that already exists). No new external API calls — reuses existing `lookup_by_mbid` / `lookup_by_release_group_mbid` methods.

## Context & Links

- **Comparable implementation**: Games "Link by IGDB ID" action
  - Controller concern: `app/controllers/concerns/igdb_input_resolvable.rb`
  - Modal partial: `app/views/admin/games/list_items_actions/modals/_link_igdb_id.html.erb`
  - Controller action: `Admin::Games::ListItemsActionsController#link_igdb_game`
- **Existing music actions**:
  - Songs: `app/controllers/admin/music/songs/list_items_actions_controller.rb` — `link_musicbrainz_recording`
  - Albums: `app/controllers/admin/music/albums/list_items_actions_controller.rb` — `link_musicbrainz_release`
- **MusicBrainz search services**:
  - `app/lib/music/musicbrainz/search/recording_search.rb` — `lookup_by_mbid`
  - `app/lib/music/musicbrainz/search/release_group_search.rb` — `lookup_by_release_group_mbid`
- **Feature doc**: `docs/features/list-wizard.md`

## Interfaces & Contracts

### Endpoints

| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| POST | `/admin/music/songs/lists/:list_id/items/:id/link_musicbrainz_url` | Link song item via MusicBrainz URL or MBID | `musicbrainz_input` (string) | admin |
| POST | `/admin/music/albums/lists/:list_id/items/:id/link_musicbrainz_url` | Link album item via MusicBrainz URL or MBID | `musicbrainz_input` (string) | admin |

> Source of truth: `config/routes.rb`

### Input Resolution

The `musicbrainz_input` parameter accepts three formats:

| Format | Example | Resolution |
|---|---|---|
| UUID (bare MBID) | `6258df90-78c7-3395-8830-e7b4328a002c` | Direct lookup by MBID |
| Full MusicBrainz URL | `https://musicbrainz.org/release-group/6258df90-...` | Parse UUID from path, lookup by MBID |
| URL with trailing path | `https://musicbrainz.org/recording/abc123.../details` | Parse UUID from path segment, lookup by MBID |

**URL patterns**:
- Albums: `https://musicbrainz.org/release-group/{uuid}`
- Songs: `https://musicbrainz.org/recording/{uuid}`

**UUID validation**: Standard MusicBrainz UUID format (`[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`)

### Behaviors

**Preconditions**:
- User is admin
- List item exists and belongs to the specified list
- `musicbrainz_input` param is present and non-blank

**Postconditions (success)**:
- Item metadata updated with MusicBrainz data (same keys as existing `link_musicbrainz_recording`/`link_musicbrainz_release` actions)
- Item marked `verified: true`
- `manual_musicbrainz_link: true` set in metadata
- `ai_match_invalid` cleared from metadata
- If a local Song/Album exists with matching MB identifier, `listable` is linked
- If no local record exists, `listable` cleared (will be created during import)
- Turbo Stream replaces item row + review stats + flash message

**Edge cases & failure modes**:
- Blank input → modal error "Please enter a MusicBrainz URL or ID"
- Invalid format (not UUID, not valid URL) → modal error "Invalid MusicBrainz URL or ID. Enter a UUID or MusicBrainz URL."
- Wrong URL type (e.g., `/release-group/` URL on songs) → modal error "Please use a MusicBrainz recording URL"
- MusicBrainz API lookup fails → modal error "Recording/Release group not found in MusicBrainz"
- Valid UUID but entity doesn't exist → modal error from API

### Non-Functionals
- No new API calls beyond existing `lookup_by_mbid` / `lookup_by_release_group_mbid`
- Admin-only access (inherits from `Admin::Music::BaseController`)

## Acceptance Criteria

- [ ] Albums review step three-dot menu includes "Link by MusicBrainz URL" option
- [ ] Songs review step three-dot menu includes "Link by MusicBrainz URL" option
- [ ] Pasting a `release-group` URL for an album item correctly parses the UUID, looks up the release group, and updates metadata identically to existing `link_musicbrainz_release` action
- [ ] Pasting a `recording` URL for a song item correctly parses the UUID, looks up the recording, and updates metadata identically to existing `link_musicbrainz_recording` action
- [ ] Pasting a bare UUID (without URL) works for both songs and albums
- [ ] Pasting a wrong URL type (e.g., `/recording/` on albums) shows appropriate error
- [ ] Invalid input (random text, malformed URL) shows error in modal
- [ ] Blank input shows error
- [ ] Modal closes on success, item row updates via Turbo Stream
- [ ] If a local Song/Album with matching MB ID exists, it gets linked as `listable`
- [ ] If no local record exists, `listable` is cleared for future import
- [ ] Controller tests cover: valid URL, valid bare UUID, wrong URL type, invalid input, blank input, API failure

### Golden Examples

```text
# Album - valid release-group URL
Input: musicbrainz_input = "https://musicbrainz.org/release-group/6258df90-78c7-3395-8830-e7b4328a002c"
Output: item.metadata["mb_release_group_id"] = "6258df90-78c7-3395-8830-e7b4328a002c"
        item.metadata["mb_release_group_name"] = "OK Computer"
        item.metadata["musicbrainz_match"] = true
        item.metadata["manual_musicbrainz_link"] = true
        item.verified = true

# Song - valid recording URL
Input: musicbrainz_input = "https://musicbrainz.org/recording/1d2be447-71b0-470a-ad38-925ecaf83c08"
Output: item.metadata["mb_recording_id"] = "1d2be447-71b0-470a-ad38-925ecaf83c08"
        item.metadata["mb_recording_name"] = "Paranoid Android"
        item.metadata["musicbrainz_match"] = true
        item.metadata["manual_musicbrainz_link"] = true
        item.verified = true

# Album - bare UUID
Input: musicbrainz_input = "6258df90-78c7-3395-8830-e7b4328a002c"
Output: Same as URL input above (UUID resolved directly)

# Song - wrong URL type error
Input: musicbrainz_input = "https://musicbrainz.org/release-group/6258df90-..."
Output: Modal error: "Please use a MusicBrainz recording URL (not release-group)"
```

## Implementation Approach

### Shared Concern: `MusicbrainzInputResolvable`

Create a new concern (modeled after `IgdbInputResolvable`) that handles URL/UUID parsing:

**File**: `app/controllers/concerns/musicbrainz_input_resolvable.rb`

```ruby
# reference only
module MusicbrainzInputResolvable
  MUSICBRAINZ_URL_PATTERN = %r{\Ahttps?://(?:www\.)?musicbrainz\.org/([a-z-]+)/([0-9a-f-]{36})}i
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  def resolve_musicbrainz_input(raw_input, expected_type:)
    # Returns [String mbid, String entity_type] or [nil, String error_message]
  end
end
```

The concern parses the input, validates the entity type matches expectations (`recording` vs `release-group`), and returns the extracted UUID.

### Controller Actions

Add a `link_musicbrainz_url` action to both controllers. This action:
1. Calls `resolve_musicbrainz_input` to parse URL/UUID
2. Delegates to the existing `link_musicbrainz_recording` / `link_musicbrainz_release` logic (extracted to a private method to avoid duplication)

### Modal Partials

Create `_link_musicbrainz_url.html.erb` for both songs and albums. Simple text input form (same pattern as `_link_igdb_id.html.erb`):
- Input field: `name="musicbrainz_input"` with placeholder showing example URL
- Submit button: "Link MusicBrainz Recording" / "Link MusicBrainz Release"

### Menu Items & Routes

- Add `link_musicbrainz_url` to `menu_items` in both item row components
- Add `link_musicbrainz_url` to `VALID_MODAL_TYPES` in both controllers
- Add `post :link_musicbrainz_url` route for both songs and albums
- Add `link_musicbrainz_url` to `item_actions_for_set_item` in both controllers

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines).
- Reuse existing `link_musicbrainz_recording` / `link_musicbrainz_release` logic — extract shared code, don't duplicate.
- Model after `IgdbInputResolvable` concern pattern.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → collect `IgdbInputResolvable` and `link_igdb_id` modal patterns
2) codebase-analyzer → verify route integration and Turbo Stream response flow
3) technical-writer → update `docs/features/list-wizard.md` with new action

### Test Seed / Fixtures
- Existing music list fixtures should suffice
- Mock MusicBrainz API responses in controller tests (same pattern as existing `link_musicbrainz_recording` tests)

---

## Implementation Notes (living)
- Approach taken: Extract & delegate pattern — extracted `perform_link_musicbrainz_recording` and `perform_link_musicbrainz_release` private methods from existing actions, both old and new actions call them.
- Important decisions: Bare UUID input intentionally bypasses entity type validation (no way to validate without API call); the API returns appropriate errors if UUID is for wrong entity type.

### Key Files Touched (paths only)
- `app/controllers/concerns/musicbrainz_input_resolvable.rb` (new)
- `app/controllers/admin/music/songs/list_items_actions_controller.rb`
- `app/controllers/admin/music/albums/list_items_actions_controller.rb`
- `app/views/admin/music/songs/list_items_actions/modals/_link_musicbrainz_url.html.erb` (new)
- `app/views/admin/music/albums/list_items_actions/modals/_link_musicbrainz_url.html.erb` (new)
- `app/components/admin/music/wizard/link_musicbrainz_url_modal_component.rb` (new)
- `app/components/admin/music/wizard/link_musicbrainz_url_modal_component.html.erb` (new)
- `app/components/admin/music/songs/wizard/item_row_component.rb`
- `app/components/admin/music/albums/wizard/item_row_component.rb`
- `config/routes.rb`
- `test/controllers/admin/music/songs/list_items_actions_controller_test.rb`
- `test/controllers/admin/music/albums/list_items_actions_controller_test.rb`

### Challenges & Resolutions
- `turbo_frame_tag` not available directly in ViewComponent templates — resolved by using `helpers.turbo_frame_tag` (matches existing `shared_modal_component.html.erb` pattern)

### Deviations From Plan
- Extracted shared `Admin::Music::Wizard::LinkMusicbrainzUrlModalComponent` ViewComponent instead of duplicating modal markup in both partials. Partials are now one-line component renders.

## Acceptance Results
- 2026-03-04, AI Agent, 87 tests / 310 assertions passing (0 failures, 0 errors)

## Future Improvements
- Could add support for `/release/` URLs (album editions) that resolve to the parent release-group
- Could add support for `/artist/` URLs to shortcut the artist linking flow

## Related PRs
-

## Documentation Updated
- [x] `docs/features/list-wizard.md` — added "Link by MusicBrainz URL" to review step item actions table
- [x] Class docs (self-documenting component/concern with clear method names)
