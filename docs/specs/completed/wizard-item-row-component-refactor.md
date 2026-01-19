# Wizard Item Row Component Refactor

## Status
- **Status**: Completed
- **Priority**: Low
- **Created**: 2026-01-19
- **Started**: 2026-01-19
- **Completed**: 2026-01-19
- **Developer**: Claude

## Overview
Refactor the review step item row rendering into a shared ViewComponent to eliminate duplication. Currently, row rendering and action menus are duplicated in 4 places: the `_item_row.html.erb` partials (used for Turbo Stream updates) and the inline rendering in `ReviewStepComponent` templates (used for initial page load).

**Non-goals:**
- Changing the visual appearance or behavior of the rows
- Adding new features to the action menu

## Context & Links
- Related: `docs/specs/completed/wizard-review-step-delete-action.md` - identified this duplication
- Feature docs: `docs/features/list-wizard.md`
- Current duplicated files:
  - `app/views/admin/music/songs/list_items_actions/_item_row.html.erb` (127 lines)
  - `app/views/admin/music/albums/list_items_actions/_item_row.html.erb` (134 lines)
  - `app/components/admin/music/songs/wizard/review_step_component.html.erb` (lines 83-144)
  - `app/components/admin/music/albums/wizard/review_step_component.html.erb` (lines 80-142)

## Interfaces & Contracts

### Domain Model (diffs only)
No model changes required.

### New Components

| Component | Purpose |
|-----------|---------|
| `Admin::Music::Wizard::ItemRowComponent` | Base component with shared row rendering logic |
| `Admin::Music::Songs::Wizard::ItemRowComponent` | Songs-specific configuration (paths, metadata keys, menu items) |
| `Admin::Music::Albums::Wizard::ItemRowComponent` | Albums-specific configuration (paths, metadata keys, menu items) |

### Component Interface

```ruby
# Base component initialization
def initialize(item:)

# Abstract methods (subclasses must implement)
def matched_title_key          # "mb_recording_name" or "mb_release_group_name"
def matched_name_fallback_key  # "song_name" or "album_name"
def matched_artists_fallback_keys  # Array of fallback keys
def supports_manual_link?      # true for albums, false for songs
def menu_items                 # Array of menu item configs
def modal_frame_id             # SharedModalComponent::FRAME_ID
def verify_item_path(item)     # Path helper
def modal_item_path(item, modal_type)  # Path helper
def destroy_item_path(item)    # Path helper
```

### Behaviors (pre/postconditions)

**Preconditions:**
- Component receives an `item` (ListItem model) as parameter

**Postconditions:**
- Renders identical HTML to current implementation
- Works both for initial page render (in ReviewStepComponent) and Turbo Stream updates (via partials)
- DOM IDs preserved: `item_row_{item.id}`, `item_menu_{item.id}`

## Acceptance Criteria
- [x] Create BaseItemRowComponent with shared logic
- [x] Create Songs::ItemRowComponent subclass
- [x] Create Albums::ItemRowComponent subclass
- [x] ReviewStepComponent uses new component instead of inline rendering
- [x] Turbo Stream partials render the component (thin wrappers)
- [x] All existing tests pass
- [x] Visual appearance is unchanged

---

## Agent Hand-Off

### Constraints
- Follow existing ViewComponent base + subclass pattern (like BaseSourceStepComponent)
- Maintain backwards compatibility with Turbo Stream updates
- Keep the same DOM structure and IDs for filtering to work
- Partials become thin wrappers that render the component

### Required Outputs
- New component files (base + 2 subclasses)
- Updated ReviewStepComponent templates
- Updated `_item_row.html.erb` partials (thin wrappers)
- Passing tests

### Sub-Agent Plan
1) codebase-pattern-finder -> find existing ViewComponent patterns for table rows
2) codebase-analyzer -> verify Turbo Stream partial rendering requirements

---

## Implementation Notes (living)
- Approach taken: Clean Architecture with base component + subclasses
- Important decisions:
  - Menu items configured via method returning array (not slots)
  - Partials stay as thin wrappers for Turbo Stream compatibility
  - All shared logic (status, badges, icons) in base component

### Key Files Touched (paths only)
- `app/components/admin/music/wizard/item_row_component.rb` (NEW - base)
- `app/components/admin/music/wizard/item_row_component.html.erb` (NEW - shared template)
- `app/components/admin/music/songs/wizard/item_row_component.rb` (NEW - songs subclass)
- `app/components/admin/music/albums/wizard/item_row_component.rb` (NEW - albums subclass)
- `app/components/admin/music/songs/wizard/review_step_component.rb` (MODIFY - remove duplicate methods)
- `app/components/admin/music/songs/wizard/review_step_component.html.erb` (MODIFY - use component)
- `app/components/admin/music/albums/wizard/review_step_component.rb` (MODIFY - remove duplicate methods)
- `app/components/admin/music/albums/wizard/review_step_component.html.erb` (MODIFY - use component)
- `app/views/admin/music/songs/list_items_actions/_item_row.html.erb` (MODIFY - thin wrapper)
- `app/views/admin/music/albums/list_items_actions/_item_row.html.erb` (MODIFY - thin wrapper)

### Challenges & Resolutions
- None

### Deviations From Plan
- Added `popover_menu_id` and `popover_close_js` helper methods to reduce template duplication for the popover close JavaScript

## Acceptance Results
- Date: 2026-01-19
- Verifier: Automated tests (129 runs, 458 assertions, 0 failures)
- All controller and component tests pass

## Future Improvements
- None identified (base component pattern already implemented)

## Related PRs
- #...

## Documentation Updated
- [x] `docs/features/list-wizard.md` - Already documented item row rendering; no changes needed
