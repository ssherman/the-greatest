# Wizard Item Row Component Refactor

## Status
- **Status**: Not Started
- **Priority**: Low
- **Created**: 2026-01-19
- **Started**:
- **Completed**:
- **Developer**:

## Overview
Refactor the review step item row rendering into a shared ViewComponent to eliminate duplication. Currently, row rendering and action menus are duplicated in 4 places: the `_item_row.html.erb` partials (used for Turbo Stream updates) and the inline rendering in `ReviewStepComponent` templates (used for initial page load).

**Non-goals:**
- Changing the visual appearance or behavior of the rows
- Adding new features to the action menu

## Context & Links
- Related: `docs/specs/completed/wizard-review-step-delete-action.md` - identified this duplication
- Feature docs: `docs/features/list-wizard.md`
- Current duplicated files:
  - `app/views/admin/music/songs/list_items_actions/_item_row.html.erb`
  - `app/views/admin/music/albums/list_items_actions/_item_row.html.erb`
  - `app/components/admin/music/songs/wizard/review_step_component.html.erb` (lines 83-142)
  - `app/components/admin/music/albums/wizard/review_step_component.html.erb` (lines 80-139)

## Interfaces & Contracts

### Domain Model (diffs only)
No model changes required.

### New Components

| Component | Purpose |
|-----------|---------|
| `Admin::Music::Songs::Wizard::ItemRowComponent` | Renders a single song list item row with action menu |
| `Admin::Music::Albums::Wizard::ItemRowComponent` | Renders a single album list item row with action menu |

Or alternatively, a shared base component with domain-specific subclasses.

### Behaviors (pre/postconditions)

**Preconditions:**
- Component receives a `list_item` and `list` as parameters

**Postconditions:**
- Renders identical HTML to current implementation
- Works both for initial page render (in ReviewStepComponent) and Turbo Stream updates (replacing partials)

## Acceptance Criteria
- [ ] Create ItemRowComponent for Songs wizard
- [ ] Create ItemRowComponent for Albums wizard
- [ ] ReviewStepComponent uses new component instead of inline rendering
- [ ] Turbo Stream partials use new component instead of duplicated HTML
- [ ] All existing tests pass
- [ ] Visual appearance is unchanged

---

## Agent Hand-Off

### Constraints
- Follow existing ViewComponent patterns in the codebase
- Maintain backwards compatibility with Turbo Stream updates
- Keep the same DOM structure and IDs for filtering to work

### Required Outputs
- New component files
- Updated ReviewStepComponent templates
- Updated or replaced `_item_row.html.erb` partials
- Passing tests

### Sub-Agent Plan
1) codebase-pattern-finder -> find existing ViewComponent patterns for table rows
2) codebase-analyzer -> verify Turbo Stream partial rendering requirements

---

## Implementation Notes (living)
- Approach taken:
- Important decisions:

### Key Files Touched (paths only)
- `app/components/admin/music/songs/wizard/item_row_component.rb`
- `app/components/admin/music/songs/wizard/item_row_component.html.erb`
- `app/components/admin/music/albums/wizard/item_row_component.rb`
- `app/components/admin/music/albums/wizard/item_row_component.html.erb`
- `app/components/admin/music/songs/wizard/review_step_component.html.erb`
- `app/components/admin/music/albums/wizard/review_step_component.html.erb`
- `app/views/admin/music/songs/list_items_actions/_item_row.html.erb`
- `app/views/admin/music/albums/list_items_actions/_item_row.html.erb`

### Challenges & Resolutions
-

### Deviations From Plan
-

## Acceptance Results
- Date, verifier, artifacts:

## Future Improvements
- Consider extracting a shared base component if Songs and Albums versions are very similar

## Related PRs
- #...

## Documentation Updated
- [ ] `docs/features/list-wizard.md`
