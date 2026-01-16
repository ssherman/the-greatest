# 115 - Artist Merge Feature

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-15
- **Started**: 2026-01-15
- **Completed**: 2026-01-15
- **Developer**: Claude

## Overview
Implement artist merge functionality in the non-Avo admin interface. Allow users to merge a source artist into a target artist, transferring all associations (albums, songs, memberships, credits, identifiers, images, categories, etc.) and deleting the source artist. The merge UI uses autocomplete to select the source artist, filtering out the current artist's ID.

**Non-goals**: Avo admin integration, bulk artist merge.

## Context & Links
- Related tasks: Song merge (completed), Album merge (completed)
- Source files (authoritative):
  - `app/lib/music/song/merger.rb` — existing Song merger pattern
  - `app/lib/music/album/merger.rb` — existing Album merger pattern
  - `app/lib/actions/admin/music/merge_song.rb` — existing MergeSong action
  - `app/lib/actions/admin/music/merge_album.rb` — existing MergeAlbum action
  - `app/controllers/admin/music/artists_controller.rb` — has `execute_action` route
  - `app/views/admin/music/artists/show.html.erb` — target view for modal

## Interfaces & Contracts

### Domain Model (diffs only)
No database migrations required. Uses existing associations on `Music::Artist`.

### Artist Associations to Merge
| Association | Foreign Key | Duplicate Handling |
|-------------|-------------|-------------------|
| `band_memberships` | `artist_id` | Skip if same member exists on target |
| `memberships` | `member_id` | Skip if same band exists on target |
| `album_artists` | `artist_id` | Skip if album already has target artist |
| `song_artists` | `artist_id` | Skip if song already has target artist |
| `credits` | `artist_id` | Transfer all (allow same role on different items) |
| `ai_chats` | `parent_id` (polymorphic) | Transfer all |
| `identifiers` | `identifiable_id` (polymorphic) | Skip if same type+value exists |
| `ranked_items` | `item_id` (polymorphic) | Delete source, recalculate for target |
| `category_items` | `item_id` (polymorphic) | Skip if category already assigned |
| `images` | `parent_id` (polymorphic) | Transfer, preserve target's primary if exists |
| `external_links` | `parent_id` (polymorphic) | Transfer all |

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| POST | `/admin/artists/:id/execute_action` | Execute merge | `action_name=MergeArtist`, `source_artist_id`, `confirm_merge` | admin |
| GET | `/admin/artists/search` | Autocomplete (existing) | `q`, `exclude_id` (new param) | admin |

> Source of truth: `config/routes.rb:150-162`

### Schemas (JSON)

**Autocomplete Response** (existing pattern):
```json
[
  { "value": 123, "text": "Artist Name" },
  { "value": 456, "text": "Another Artist" }
]
```

**Action Result** (existing pattern):
```json
{
  "status": "success|error",
  "message": "Successfully merged 'Source Artist' into 'Target Artist'."
}
```

### Behaviors (pre/postconditions)

**Preconditions**:
- User is authenticated admin
- Source artist exists and is different from target artist
- User confirms merge via checkbox

**Postconditions/effects**:
- All source artist associations transferred to target artist (with duplicate handling)
- Source artist destroyed
- Target artist `touch`ed
- Search reindex queued for target artist
- Ranking recalculation scheduled for affected configurations

**Edge cases & failure modes**:
- Source artist ID not found → error message
- Source artist ID equals target artist ID → error message
- Constraint violation (duplicate record) → transaction rolled back, error message
- Missing confirmation checkbox → validation error

### Non-Functionals
- **Performance**: Transaction should complete within 5s for typical artist (~100 associations)
- **N+1**: Use `find_each` for batch processing, `update_all` where possible
- **Security**: Admin-only action; action class validates single-model context

## Acceptance Criteria
- [x] `Music::Artist::Merger` service exists following Song/Album merger pattern
- [x] `Actions::Admin::Music::MergeArtist` action class exists with proper validation
- [x] Merge modal appears in Actions dropdown on artist show page
- [x] Autocomplete searches artists, excludes current artist ID
- [x] All 10 association types transferred correctly (ai_chats excluded per user request)
- [x] Source artist destroyed after successful merge
- [x] Target artist search index refreshed
- [x] Affected ranking configurations recalculated
- [x] Error messages displayed for invalid input
- [x] Modal closes on successful merge with flash message
- [x] Tests pass for merger service, action class, and controller

### Golden Examples

**Input**:
- Target artist: ID 100 "The Beatles" (has 10 albums, 50 songs)
- Source artist: ID 200 "Beatles" (has 2 albums, 5 songs, 1 shared album with target)

**Output**:
- Target artist: ID 100 "The Beatles" (has 11 albums, 55 songs — 1 album was duplicate)
- Source artist: Destroyed
- Stats: `{ albums: 1, songs: 5, ... }` (duplicate album not counted)
- Message: "Successfully merged 'Beatles' (ID: 200) into 'The Beatles'. The source artist has been deleted."

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → collect comparable patterns (done in spec creation)
2) codebase-analyzer → verify data flow & integration points (done in spec creation)
3) Implementation sequence:
   - Create `app/lib/music/artist/merger.rb`
   - Create `app/lib/actions/admin/music/merge_artist.rb`
   - Update `app/controllers/admin/music/artists_controller.rb` search to support `exclude_id`
   - Add merge modal to `app/views/admin/music/artists/show.html.erb`
   - Add tests for merger, action, and controller

### Test Seed / Fixtures
- Use existing `music_artists` fixtures
- Create two artists with overlapping associations for merge testing

---

## Implementation Notes (living)
- Approach taken: Followed existing Song/Album merger patterns exactly
- Important decisions:
  - Removed ai_chats from merge (not needed per user feedback)
  - Used `find_each` for batch processing to avoid memory issues
  - Duplicate handling: destroy source record when target already has the association

### Key Files Touched (paths only)
- `app/lib/music/artist/merger.rb` (new)
- `app/lib/actions/admin/music/merge_artist.rb` (new)
- `app/controllers/admin/music/artists_controller.rb` (updated execute_action & search)
- `app/views/admin/music/artists/show.html.erb` (added modal & dropdown item)
- `test/lib/music/artist/merger_test.rb` (new)
- `test/lib/actions/admin/music/merge_artist_test.rb` (new)
- `test/controllers/admin/music/artists_controller_test.rb` (updated)

### Challenges & Resolutions
- Membership tests had fixture conflicts with Pink Floyd members - resolved by creating fresh test artists

### Deviations From Plan
- Removed ai_chats merge per user feedback

## Acceptance Results
- Date: 2026-01-15
- Verifier: Automated tests (72 tests, 179 assertions, 0 failures)
- All tests pass for merger service, action class, and controller

## Future Improvements
- Bulk artist merge from index page
- Merge history/audit log
- Undo merge capability (would require soft-delete pattern)

## Related PRs
- #…

## Documentation Updated
- [x] `docs/lib/music/artist/merger.md` - Merger service documentation
- [x] `docs/admin/actions/music/merge_artist.md` - Admin action documentation

---

## Reference: Existing Merger Pattern (≤40 lines, non-authoritative)

```ruby
# reference only — see app/lib/music/song/merger.rb for authoritative code
def merge_all_associations
  merge_tracks
  merge_identifiers
  merge_category_items
  merge_external_links
  merge_list_items
  merge_song_relationships
  merge_inverse_song_relationships
  target_song.touch
end

def merge_category_items
  count = 0
  source_song.category_items.find_each do |category_item|
    target_song.category_items.find_or_create_by!(
      category_id: category_item.category_id
    )
    count += 1
  end
  @stats[:category_items] = count
end
```

## Reference: Existing Modal Pattern (≤40 lines, non-authoritative)

```erb
<%# reference only — see app/views/admin/music/songs/show.html.erb:336-383 %>
<dialog id="merge-song-modal" class="modal">
  <div class="modal-box max-w-2xl">
    <h3 class="font-bold text-lg">Merge Another Song Into This One</h3>
    <%= form_with url: execute_action_admin_song_path(@song),
                  method: :post,
                  data: { controller: "modal-form", modal_form_modal_id_value: "merge-song-modal" } do |f| %>
      <%= f.hidden_field :action_name, value: "MergeSong" %>
      <%# ... form fields ... %>
    <% end %>
  </div>
</dialog>
```
