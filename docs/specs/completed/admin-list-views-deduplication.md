# Admin List Views Deduplication

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-02-25
- **Started**: 2026-02-26
- **Completed**: 2026-02-26
- **Developer**: Claude

## Overview
Consolidate the 18 near-identical admin list view files (across games, albums, songs) into shared ViewComponents. Currently each domain has 6 view files (`_form`, `_table`, `show`, `index`, `new`, `edit`) that are ~92% duplicated — differences are limited to route helpers, domain nouns, placeholder text, and one optional field (`musicbrainz_series_id` for music domains only). The goal is to replace these with shared components so that changes touch 1 file instead of 3+.

**Non-goals**: Refactoring the controllers (already well-factored via `Admin::ListsBaseController`), changing the wizard components, or adding books/movies admin views.

## Context & Links
- Related tasks: `docs/specs/completed/list-model-field-cleanup.md` (recent spec that had to update all 3 form + show files)
- Controllers (authoritative): `app/controllers/admin/lists_base_controller.rb`, `app/controllers/admin/games/lists_controller.rb`, `app/controllers/admin/music/lists_controller.rb`, `app/controllers/admin/music/albums/lists_controller.rb`, `app/controllers/admin/music/songs/lists_controller.rb`
- Existing shared helper: `app/helpers/admin/music/lists_helper.rb` (provides `count_items_json`, `items_json_to_string`)
- Existing shared components pattern: `app/components/admin/add_item_to_list_modal_component.rb` (uses `case @list.class.name` for domain switching)

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes required. This is a view-layer refactoring only.

### Component Architecture

**6 new ViewComponents** under `app/components/admin/lists/`:

| Component | Replaces | Config Inputs |
|---|---|---|
| `Admin::Lists::FormComponent` | 3x `_form.html.erb` (~350 lines each) | `list`, `domain_config` |
| `Admin::Lists::ShowComponent` | 3x `show.html.erb` (~320 lines each) | `list`, `domain_config` |
| `Admin::Lists::IndexComponent` | 3x `index.html.erb` (~52 lines each) | `lists`, `pagy`, `domain_config`, `selected_status`, `search_query` |
| `Admin::Lists::TableComponent` | 3x `_table.html.erb` (~221 lines each) | `lists`, `pagy`, `domain_config`, `search_query` |
| `Admin::Lists::NewComponent` | 3x `new.html.erb` (14 lines each) | `list`, `domain_config` |
| `Admin::Lists::EditComponent` | 3x `edit.html.erb` (14 lines each) | `list`, `domain_config` |

**Domain config** — Each controller subclass provides a config hash (or method) with domain-specific values. The `Admin::ListsBaseController` already defines abstract methods (`item_label`, `lists_path`, `list_path`, etc.) that can be composed into this config. Add a new method to the base controller:

```ruby
# reference only — app/controllers/admin/lists_base_controller.rb
def domain_config
  {
    item_label: item_label,                    # "Game", "Album", "Song"
    item_label_plural: item_label.pluralize,   # "Games", "Albums", "Songs"
    lists_path: lists_path,
    list_path_proc: method(:list_path),
    new_list_path: new_list_path,
    edit_list_path_proc: method(:edit_list_path),
    wizard_path_proc: method(:wizard_path),
    items_count_method: items_count_name,       # "games_count"
    source_placeholder: source_placeholder,
    country_placeholder: country_placeholder,
    info_alert_text: info_alert_text,
    extra_fields: extra_form_fields,            # [:musicbrainz_series_id] for music
    extra_show_fields: extra_show_fields,       # [:musicbrainz_series_id] for music
  }
end
```

### Behaviors (pre/postconditions)
- **Precondition**: All existing admin list controller tests pass before refactoring.
- **Postcondition**: All existing tests pass after refactoring with zero behavior changes.
- **Invariant**: Domain-specific views render identically to current output (same HTML structure, same CSS classes, same Turbo frames).
- **Edge case**: `musicbrainz_series_id` field only renders for music domain lists (albums, songs), not for games.
- **Edge case**: Games info alert has different wording than music ("Add Game button on show page" vs "Items JSON import").
- **Edge case**: Games show page has `data-testid` on back button; music pages do not. Normalize this (add to all or remove from games — recommend adding to all for test consistency).
- **Edge case**: `Admin::Music::ListsController#item_label` returns `"Album"` even for songs. This is a pre-existing bug — fix as part of this work.

### Non-Functionals
- No N+1 changes (views don't add queries).
- No new JavaScript or Stimulus controllers needed.
- Components must work with Turbo frames (the table partial is loaded inside `turbo_frame_tag "lists_table"`).
- Components must be compatible with all 3 admin layouts (`games/admin`, `music/admin`).

## Acceptance Criteria
- [x] `Admin::Lists::FormComponent` renders the full list form for all 3 domains, with `musicbrainz_series_id` conditionally shown for music domains only.
- [x] `Admin::Lists::ShowComponent` renders the full show page for all 3 domains, with `musicbrainz_series_id` conditionally shown for music domains only.
- [x] `Admin::Lists::IndexComponent` renders the index page with search, status filter, and turbo frame for all 3 domains.
- [x] `Admin::Lists::TableComponent` renders the sortable table with domain-specific item count column and route helpers for all 3 domains.
- [x] `Admin::Lists::NewComponent` and `Admin::Lists::EditComponent` render the new/edit wrapper pages for all 3 domains.
- [x] `domain_config` method added to `Admin::ListsBaseController` with overridable defaults; subclasses override domain-specific values.
- [x] Original domain-specific ERB files replaced with single-line renders of the shared components.
- [x] All existing controller tests pass without modification (or with minimal route-helper-only changes).
- [x] `count_items_json` and `items_json_to_string` helper methods are accessible from the shared components (move to `Admin::ListsHelper` or include in component).
- [x] `item_label` bug fixed: songs controller returns `"Song"`, not `"Album"`.
- [x] `data-testid` on back button normalized across all domains.

### Golden Examples

```text
Input: Admin visits /admin/games/lists/new
Output: Renders Admin::Lists::FormComponent with domain_config.item_label="Game",
        source_placeholder="e.g., IGN, GameSpot, Metacritic",
        no musicbrainz_series_id field shown,
        submit button says "Create Game List"

Input: Admin visits /admin/music/albums/lists/42
Output: Renders Admin::Lists::ShowComponent with domain_config.item_label="Album",
        musicbrainz_series_id shown in Metadata card (if present),
        items section header says "Albums",
        wizard link goes to admin_albums_list_wizard_path
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.
- ViewComponents should follow existing patterns in `app/components/admin/`.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests for the Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → collect existing ViewComponent patterns in `app/components/admin/`
2) codebase-analyzer → verify how controllers pass data to views, confirm helper accessibility
3) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- Existing fixtures and controller tests are sufficient. No new fixtures needed.
- Existing test files: `test/controllers/admin/games/lists_controller_test.rb`, `test/controllers/admin/music/albums/lists_controller_test.rb`, `test/controllers/admin/music/songs/lists_controller_test.rb`

---

## Files To Update

### New Files (create)
- `app/components/admin/lists/form_component.rb`
- `app/components/admin/lists/form_component.html.erb`
- `app/components/admin/lists/show_component.rb`
- `app/components/admin/lists/show_component.html.erb`
- `app/components/admin/lists/index_component.rb`
- `app/components/admin/lists/index_component.html.erb`
- `app/components/admin/lists/table_component.rb`
- `app/components/admin/lists/table_component.html.erb`
- `app/components/admin/lists/new_component.rb`
- `app/components/admin/lists/new_component.html.erb`
- `app/components/admin/lists/edit_component.rb`
- `app/components/admin/lists/edit_component.html.erb`

### Existing Files (modify)
- `app/controllers/admin/lists_base_controller.rb` — add `domain_config` method + helper methods (`source_placeholder`, `country_placeholder`, `info_alert_text`, `extra_form_fields`, `extra_show_fields`, `wizard_path`)
- `app/controllers/admin/games/lists_controller.rb` — override domain-specific config methods
- `app/controllers/admin/music/lists_controller.rb` — override domain-specific config methods, fix `item_label` for songs
- `app/controllers/admin/music/albums/lists_controller.rb` — override domain-specific config methods
- `app/controllers/admin/music/songs/lists_controller.rb` — override domain-specific config methods, add `item_label "Song"`
- `app/helpers/admin/music/lists_helper.rb` — move to `app/helpers/admin/lists_helper.rb` (or make shared)

### Existing Files (simplify to component renders)
- `app/views/admin/games/lists/_form.html.erb` — replace ~345 lines with component render
- `app/views/admin/games/lists/_table.html.erb` — replace ~221 lines with component render
- `app/views/admin/games/lists/show.html.erb` — replace ~315 lines with component render
- `app/views/admin/games/lists/index.html.erb` — replace ~52 lines with component render
- `app/views/admin/games/lists/new.html.erb` — replace ~14 lines with component render
- `app/views/admin/games/lists/edit.html.erb` — replace ~14 lines with component render
- `app/views/admin/music/albums/lists/_form.html.erb` — same
- `app/views/admin/music/albums/lists/_table.html.erb` — same
- `app/views/admin/music/albums/lists/show.html.erb` — same
- `app/views/admin/music/albums/lists/index.html.erb` — same
- `app/views/admin/music/albums/lists/new.html.erb` — same
- `app/views/admin/music/albums/lists/edit.html.erb` — same
- `app/views/admin/music/songs/lists/_form.html.erb` — same
- `app/views/admin/music/songs/lists/_table.html.erb` — same
- `app/views/admin/music/songs/lists/show.html.erb` — same
- `app/views/admin/music/songs/lists/index.html.erb` — same
- `app/views/admin/music/songs/lists/new.html.erb` — same
- `app/views/admin/music/songs/lists/edit.html.erb` — same

---

## Implementation Notes (living)
- Approach taken: Plain Hash `domain_config` method on the base controller, exposed via `helper_method`. Each component receives the hash and uses it for route helpers, labels, placeholders, and conditional fields. Route helpers passed as `Method` procs bound to the controller instance.
- Important decisions:
  - `content_for :title` stays in the thin wrapper ERB views (not in the ViewComponent templates) because ViewComponents render in an isolated context that cannot write to the layout's content buffer.
  - ViewComponents use `helpers.turbo_frame_tag` (not bare `turbo_frame_tag`) since Turbo helpers aren't directly available in ViewComponent templates.
  - Helper methods `count_items_json` and `items_json_to_string` moved to a new shared `Admin::ListsHelper` module. The existing `Admin::Music::ListsHelper` now simply `include`s the shared module for backward compatibility.
  - Components generated via `rails generate view_component:component` per project convention. Empty test stubs removed since existing controller integration tests provide full coverage.

### Key Files Touched (paths only)
- `app/components/admin/lists/form_component.rb` + `.html.erb`
- `app/components/admin/lists/show_component.rb` + `.html.erb`
- `app/components/admin/lists/index_component.rb` + `.html.erb`
- `app/components/admin/lists/table_component.rb` + `.html.erb`
- `app/components/admin/lists/new_component.rb` + `.html.erb`
- `app/components/admin/lists/edit_component.rb` + `.html.erb`
- `app/controllers/admin/lists_base_controller.rb`
- `app/controllers/admin/games/lists_controller.rb`
- `app/controllers/admin/music/lists_controller.rb`
- `app/controllers/admin/music/albums/lists_controller.rb`
- `app/controllers/admin/music/songs/lists_controller.rb`
- `app/helpers/admin/lists_helper.rb` (new)
- `app/helpers/admin/music/lists_helper.rb` (simplified)
- 18 view files across `admin/games/lists/`, `admin/music/albums/lists/`, `admin/music/songs/lists/`
- `e2e/pages/games/admin/lists-page.ts` (updated locator for "New Game List" button)

### Challenges & Resolutions
- **`content_for` in ViewComponent**: Discovered that `content_for :title` inside ViewComponent templates doesn't propagate to the layout. Resolved by keeping `content_for` in the thin wrapper ERB views.
- **Turbo helpers in ViewComponent**: `turbo_frame_tag` is not directly available in ViewComponent templates. Resolved by using `helpers.turbo_frame_tag` (following existing pattern in `Admin::Music::Wizard::SharedModalComponent`).
- **E2E test locator update**: The shared `IndexComponent` normalized the "New List" button text to "New Game List" (consistent with music domains which already used "New Album List" / "New Song List"). Updated `e2e/pages/games/admin/lists-page.ts` locator to match.

### Deviations From Plan
- The spec suggested `_table.html.erb` partials could be removed entirely, but they were kept as thin wrappers since they're still referenced by the `render "table"` call pattern. The `IndexComponent` now renders `TableComponent` directly inside its template, so the partial wrappers are only needed as a fallback.
- Games index "New List" button text changed from "New List" to "New Game List" for consistency with music domains. E2E page object updated accordingly.

## Acceptance Results
- Date: 2026-02-26
- Verifier: Automated test suite
- Unit/integration: 3970 runs, 10357 assertions, 0 failures, 0 errors, 0 skips
- E2E: 135 passed, 0 failed
- All existing controller tests pass without any modification

## Future Improvements
- When books/movies admin list CRUD is built, they get shared components for free — just wire up a controller subclass.
- Consider extracting the sortable column header into its own sub-component (repeated SVG pattern for sort arrows).
- Consider extracting the status badge rendering into a shared helper/component.

## Related PRs
- (pending commit)

## Documentation Updated
- [x] Spec moved to `docs/specs/completed/`
