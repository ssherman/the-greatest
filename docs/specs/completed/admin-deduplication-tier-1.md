# Admin Deduplication — Tier 1 (Categories, Artist Associations, Bulk Actions)

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-02-26
- **Started**: 2026-02-27
- **Completed**: 2026-02-27
- **Developer**: Claude

## Overview
Consolidate three areas of near-identical admin code into shared abstractions. This follows the successful pattern established by the `Admin::Lists::*` ViewComponent deduplication (see `docs/specs/completed/admin-list-views-deduplication.md`).

**Scope**:
1. **Categories** — Music and Games category controllers + 6 view file pairs (~95% identical)
2. **Artist associations** — `AlbumArtistsController` and `SongArtistsController` (~95% identical)
3. **Bulk actions** — `bulk_verify`, `bulk_skip`, `bulk_delete` duplicated verbatim across 3 `ListItemsActions` controllers

**Non-goals**: Deduplicating item show pages, item tables, item forms, or games support controllers (Companies, Platforms, Series). Those are Tier 2/3 opportunities for future work.

## Context & Links
- Prior art: `docs/specs/completed/admin-list-views-deduplication.md` — established the `domain_config` hash pattern
- Categories controllers: `app/controllers/admin/music/categories_controller.rb`, `app/controllers/admin/games/categories_controller.rb`
- Artist association controllers: `app/controllers/admin/music/album_artists_controller.rb`, `app/controllers/admin/music/song_artists_controller.rb`
- ListItemsActions concern: `app/controllers/concerns/list_items_actions.rb`
- ListItemsActions controllers: `app/controllers/admin/games/list_items_actions_controller.rb`, `app/controllers/admin/music/albums/list_items_actions_controller.rb`, `app/controllers/admin/music/songs/list_items_actions_controller.rb`
- Existing dedup patterns to follow: `app/controllers/admin/lists_base_controller.rb` (domain_config), `app/controllers/admin/ranking_configurations_controller.rb` (base class with overridable methods)

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes required. This is a controller/view-layer refactoring only.

### Part 1: Categories Deduplication

#### Controller Architecture

**New base controller**: `Admin::CategoriesBaseController` (inherits from `Admin::BaseController`)

The two existing controllers are ~95% identical. Differences are confined to:
- Model class (`Music::Category` vs `Games::Category`)
- Strong params key (`:music_category` vs `:games_category`)
- Route helpers (`admin_category_path` vs `admin_games_category_path`)
- Show page stats (music: albums/artists/songs counts; games: games count only)

```ruby
# reference only — app/controllers/admin/categories_base_controller.rb
class Admin::CategoriesBaseController < Admin::BaseController
  # Subclasses must implement:
  #   model_class         → Music::Category or Games::Category
  #   param_key           → :music_category or :games_category
  #   category_path(cat)  → route helper
  #   categories_path     → route helper
  #   show_stats(cat)     → hash of {label: count} for sidebar stats
  #   permitted_params    → array of permitted param names
end
```

Each domain controller reduces to ~15 lines overriding abstract methods.

#### ViewComponent Architecture

**6 new ViewComponents** under `app/components/admin/categories/`:

| Component | Replaces | Config Inputs |
|---|---|---|
| `Admin::Categories::IndexComponent` | 2x `index.html.erb` (~41 lines each) | `categories`, `pagy`, `domain_config` |
| `Admin::Categories::TableComponent` | 2x `_table.html.erb` (~118 lines each) | `categories`, `pagy`, `domain_config` |
| `Admin::Categories::ShowComponent` | 2x `show.html.erb` (~161-171 lines each) | `category`, `domain_config`, `stats` |
| `Admin::Categories::FormComponent` | 2x `_form.html.erb` (~96 lines each) | `category`, `domain_config` |
| `Admin::Categories::NewComponent` | 2x `new.html.erb` (~17 lines each) | `category`, `domain_config` |
| `Admin::Categories::EditComponent` | 2x `edit.html.erb` (~18 lines each) | `category`, `domain_config` |

**Domain config** — follows the `Admin::Lists` pattern:

```ruby
# reference only
def domain_config
  {
    model_class: model_class,
    category_path_proc: method(:category_path),
    categories_path: categories_path,
    new_category_path: new_category_path,
    edit_category_path_proc: method(:edit_category_path),
    domain_label: domain_label,   # "Music" or "Games"
    subtitle: subtitle            # "Manage music genres..." or "Manage game genres..."
  }
end
```

### Part 2: Artist Associations Deduplication

#### Controller Architecture

**New concern**: `Admin::Music::ArtistAssociationActions` (or base controller)

The two controllers (`AlbumArtistsController`, `SongArtistsController`) are ~95% identical. Differences:
- Join model class (`Music::AlbumArtist` vs `Music::SongArtist`)
- Strong params key (`:music_album_artist` vs `:music_song_artist`)
- Parent resource name (`:album` vs `:song`)
- Policy class (`Music::AlbumPolicy` vs `Music::SongPolicy`)
- Turbo frame IDs (`album_artists_list` vs `song_artists_list`)
- Partial paths (`admin/music/albums/artists_list` vs `admin/music/songs/artists_list`)
- Route helpers (`admin_album_path` vs `admin_song_path`)

```ruby
# reference only — app/controllers/concerns/artist_association_actions.rb
module ArtistAssociationActions
  extend ActiveSupport::Concern
  # Subclasses must implement:
  #   join_model_class        → Music::AlbumArtist or Music::SongArtist
  #   param_key               → :music_album_artist or :music_song_artist
  #   parent_resource_name    → :album or :song
  #   parent_policy_class     → Music::AlbumPolicy or Music::SongPolicy
  #   parent_path(resource)   → admin_album_path or admin_song_path
  #   parent_frame_id         → "album_artists_list" or "song_artists_list"
  #   artist_frame_id         → "artist_albums_list" or "artist_songs_list"
  #   parent_partial_path     → "admin/music/albums/artists_list"
  #   artist_partial_path     → "admin/music/artists/albums_list"
end
```

Each controller reduces to ~20 lines overriding abstract methods.

### Part 3: Bulk Actions into ListItemsActions Concern

#### Current State
`bulk_verify`, `bulk_skip`, and `bulk_delete` are **verbatim identical** across 3 controllers:
- `app/controllers/admin/games/list_items_actions_controller.rb`
- `app/controllers/admin/music/albums/list_items_actions_controller.rb`
- `app/controllers/admin/music/songs/list_items_actions_controller.rb`

#### Target State
Move all 3 methods into the existing `ListItemsActions` concern (`app/controllers/concerns/list_items_actions.rb`). No abstraction needed — the code is literally identical. Just cut from the 3 controllers and paste into the concern.

### Behaviors (pre/postconditions)
- **Precondition**: All existing controller tests pass before refactoring.
- **Postcondition**: All existing tests pass after refactoring with zero behavior changes.
- **Invariant**: All views render identically to current output (same HTML structure, same CSS classes, same Turbo frames).
- **Edge case**: Music categories show page has 3 stat blocks (albums, artists, songs); games has 1 (games). The `stats` input handles this via a variable-length hash.
- **Edge case**: Games categories views have `data-testid` on back button and `data: { turbo_frame: "_top" }` on empty-state button; music does not. Normalize by adding to both (consistent with list dedup spec decision).
- **Edge case**: `AlbumArtistsController` uses `Music::AlbumPolicy` while `SongArtistsController` uses `Music::SongPolicy`. The concern must accept a configurable policy class.

### Non-Functionals
- No N+1 changes (views don't add queries).
- No new JavaScript or Stimulus controllers needed.
- Components must work with Turbo frames (category table is inside `turbo_frame_tag "categories_table"`).
- Components must be compatible with both admin layouts (`games/admin`, `music/admin`).

## Acceptance Criteria
- [x] `Admin::CategoriesBaseController` extracts shared CRUD logic; music and games subclasses override only domain-specific methods (~15 lines each).
- [x] 6 `Admin::Categories::*` ViewComponents render identically to current domain-specific views.
- [x] `Admin::Categories::ShowComponent` conditionally renders N stat blocks from a `stats` hash.
- [x] `Admin::Categories::FormComponent` uses `domain_config[:model_class]` for the parent category query.
- [x] Original category ERB files replaced with single-line component renders.
- [x] `ArtistAssociationActions` concern extracts shared create/update/destroy + context-inference logic.
- [x] `AlbumArtistsController` and `SongArtistsController` reduced to ~15 lines each overriding abstract methods.
- [x] `bulk_verify`, `bulk_skip`, `bulk_delete` moved into `ListItemsActions` concern.
- [x] Both `ListItemsActionsController` subclasses that had them no longer define these 3 methods.
- [x] `data-testid` on back button normalized across both category domains.
- [x] `data: { turbo_frame: "_top" }` on empty-state button normalized across both category domains.
- [x] All existing controller tests pass without modification.

### Golden Examples

```text
Input: Admin visits /admin/categories/new (music)
Output: Renders Admin::Categories::FormComponent with domain_config.model_class=Music::Category,
        parent dropdown queries Music::Category.active,
        submit button says "Create Category"

Input: Admin visits /admin/games/categories/42
Output: Renders Admin::Categories::ShowComponent with domain_config.domain_label="Games",
        sidebar shows 1 stat block: "Games: @games_count",
        back button has data-testid="back-button"

Input: Admin bulk-verifies 5 items on album list wizard review step
Output: ListItemsActions concern handles bulk_verify (same as before),
        5 items marked verified, redirects to review step with flash
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.
- ViewComponents should follow existing patterns in `app/components/admin/`.
- Use `domain_config` hash pattern established by `Admin::Lists::*` components.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests for the Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> collect existing ViewComponent and base controller patterns in `app/components/admin/` and `app/controllers/admin/`
2) codebase-analyzer -> verify how controllers pass data to views, confirm helper/concern accessibility
3) technical-writer -> update docs and cross-refs

### Test Seed / Fixtures
- Existing fixtures and controller tests are sufficient. No new fixtures needed.
- Existing test files:
  - `test/controllers/admin/music/categories_controller_test.rb`
  - `test/controllers/admin/games/categories_controller_test.rb`
  - `test/controllers/admin/music/album_artists_controller_test.rb`
  - `test/controllers/admin/music/song_artists_controller_test.rb`
  - `test/controllers/admin/games/list_items_actions_controller_test.rb`
  - `test/controllers/admin/music/albums/list_items_actions_controller_test.rb`
  - `test/controllers/admin/music/songs/list_items_actions_controller_test.rb`

---

## Files To Update

### New Files (create)
- `app/controllers/admin/categories_base_controller.rb`
- `app/components/admin/categories/index_component.rb` + `.html.erb`
- `app/components/admin/categories/table_component.rb` + `.html.erb`
- `app/components/admin/categories/show_component.rb` + `.html.erb`
- `app/components/admin/categories/form_component.rb` + `.html.erb`
- `app/components/admin/categories/new_component.rb` + `.html.erb`
- `app/components/admin/categories/edit_component.rb` + `.html.erb`
- `app/controllers/concerns/artist_association_actions.rb`

### Existing Files (modify)
- `app/controllers/admin/music/categories_controller.rb` — reduce to subclass of base
- `app/controllers/admin/games/categories_controller.rb` — reduce to subclass of base
- `app/controllers/admin/music/album_artists_controller.rb` — include concern, reduce to overrides
- `app/controllers/admin/music/song_artists_controller.rb` — include concern, reduce to overrides
- `app/controllers/concerns/list_items_actions.rb` — add `bulk_verify`, `bulk_skip`, `bulk_delete`
- `app/controllers/admin/games/list_items_actions_controller.rb` — remove bulk action methods
- `app/controllers/admin/music/albums/list_items_actions_controller.rb` — remove bulk action methods
- `app/controllers/admin/music/songs/list_items_actions_controller.rb` — remove bulk action methods

### Existing Files (simplify to component renders)
- `app/views/admin/music/categories/index.html.erb`
- `app/views/admin/music/categories/_table.html.erb`
- `app/views/admin/music/categories/show.html.erb`
- `app/views/admin/music/categories/_form.html.erb`
- `app/views/admin/music/categories/new.html.erb`
- `app/views/admin/music/categories/edit.html.erb`
- `app/views/admin/games/categories/index.html.erb`
- `app/views/admin/games/categories/_table.html.erb`
- `app/views/admin/games/categories/show.html.erb`
- `app/views/admin/games/categories/_form.html.erb`
- `app/views/admin/games/categories/new.html.erb`
- `app/views/admin/games/categories/edit.html.erb`

---

## Implementation Notes (living)
- Approach taken: Same `domain_config` hash pattern established by `Admin::Lists::*` components. Base controller assembles config, exposed via `helper_method`. ViewComponents receive the hash for route helpers, labels, and conditional rendering.
- Important decisions:
  - `content_for :title` stays in the thin wrapper ERB views (same pattern as lists dedup — ViewComponents can't write to the layout's content buffer).
  - ViewComponents use `helpers.turbo_frame_tag`, `helpers.button_to`, `helpers.form_with`, `helpers.params` since these helpers aren't directly available in ViewComponent templates.
  - `ArtistAssociationActions` concern uses `parent_resource_name` symbol to dynamically access the parent model, avoiding hardcoded `@album`/`@song` references.
  - Stats on show page are passed as a hash `{label => count}` with cycling colors (`text-primary`, `text-secondary`, `text-accent`).
  - Bulk actions only existed in 2 controllers (games and albums), not 3 as originally estimated — songs controller didn't have them.
  - Empty component test stubs removed since existing controller integration tests provide full coverage.

### Key Files Touched (paths only)
- `app/controllers/admin/categories_base_controller.rb` (new)
- `app/controllers/admin/music/categories_controller.rb`
- `app/controllers/admin/games/categories_controller.rb`
- `app/components/admin/categories/index_component.rb` + `.html.erb` (new)
- `app/components/admin/categories/table_component.rb` + `.html.erb` (new)
- `app/components/admin/categories/show_component.rb` + `.html.erb` (new)
- `app/components/admin/categories/form_component.rb` + `.html.erb` (new)
- `app/components/admin/categories/new_component.rb` + `.html.erb` (new)
- `app/components/admin/categories/edit_component.rb` + `.html.erb` (new)
- `app/controllers/concerns/artist_association_actions.rb` (new)
- `app/controllers/admin/music/album_artists_controller.rb`
- `app/controllers/admin/music/song_artists_controller.rb`
- `app/controllers/concerns/list_items_actions.rb`
- `app/controllers/admin/games/list_items_actions_controller.rb`
- `app/controllers/admin/music/albums/list_items_actions_controller.rb`
- 12 view files across `admin/music/categories/`, `admin/games/categories/`

### Challenges & Resolutions
- None — the patterns established by the lists dedup translated cleanly.

### Deviations From Plan
- Spec originally stated bulk actions were duplicated across 3 controllers; they were only in 2 (games and albums). Songs controller didn't have them.
- `AlbumArtistsController` and `SongArtistsController` reduced to ~15 lines each (spec said ~20).

## Acceptance Results
- Date: 2026-02-27
- Verifier: Automated test suite
- Unit/integration: 3976 runs, 10357 assertions, 0 failures, 0 errors, 0 skips
- All existing controller tests pass without any modification

## Future Improvements
- Tier 2 deduplication: item index pages, edit/new wrappers, Add Image modal
- Tier 3 deduplication: item show pages, item tables, item forms, games support controllers (Companies, Platforms, Series)
- When books/movies admin categories are built, they get shared components for free

## Related PRs
- (pending commit)

## Documentation Updated
- [x] Spec file updated with implementation notes and acceptance results
