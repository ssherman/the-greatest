# 113 - Admin Category Sections on Show Pages

## Status
- **Status**: Not Started
- **Priority**: Low
- **Created**: 2026-01-12
- **Started**:
- **Completed**:
- **Developer**:

## Overview
Add category management sections to the admin show pages for Albums and Songs. This will allow admins to view and manage category associations directly from the entity's show page, similar to how artists show their categories.

**Non-goals:**
- No category management on Artist show page (already displays categories as read-only badges)
- No inline category creation (use Categories admin for that)
- No bulk category assignment from index pages

## Context & Links
- Related tasks: Spec 112 (Custom Admin Music Categories)
- Source files:
  - `app/views/admin/music/albums/show.html.erb`
  - `app/views/admin/music/songs/show.html.erb`
  - `app/views/admin/music/artists/show.html.erb` (reference for category display pattern)
- Existing patterns: `app/models/category_item.rb`

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes required. Uses existing `CategoryItem` polymorphic join model.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| POST | /admin/albums/:album_id/category_items | Add category to album | `category_id` | admin/editor |
| DELETE | /admin/albums/:album_id/category_items/:id | Remove category from album | | admin/editor |
| POST | /admin/songs/:song_id/category_items | Add category to song | `category_id` | admin/editor |
| DELETE | /admin/songs/:song_id/category_items/:id | Remove category from song | | admin/editor |

> Source of truth: `config/routes.rb`

### Schemas (JSON)
Not applicable - standard Rails form submissions.

### Behaviors (pre/postconditions)

**Add Category:**
- Preconditions: Category exists, entity exists, not already associated
- Postconditions: CategoryItem created linking category to entity
- Failure: Re-render with error if duplicate

**Remove Category:**
- Preconditions: CategoryItem exists
- Postconditions: CategoryItem destroyed
- Note: Does not affect category's item_count (counter cache should be updated)

### Non-Functionals
- No N+1: Eager load categories on show pages
- Security: Admin/editor role required
- UX: Use modal or dropdown for category selection with autocomplete

## Acceptance Criteria
- [ ] Album show page has "Categories" section displaying associated categories
- [ ] Song show page has "Categories" section displaying associated categories
- [ ] Admin can add a category to an album via dropdown/modal
- [ ] Admin can remove a category from an album
- [ ] Admin can add a category to a song via dropdown/modal
- [ ] Admin can remove a category from a song
- [ ] Category badges link to admin category show page
- [ ] Adding duplicate category shows appropriate error
- [ ] Category item_count is updated when associations change

### Golden Examples
```text
Input: Add "Rock" category to album "Dark Side of the Moon"
Output: CategoryItem created, category badge appears in Categories section

Input: Remove "Progressive Rock" category from song "Comfortably Numb"
Output: CategoryItem destroyed, badge removed from Categories section
```

---

## Agent Hand-Off

### Constraints
- Follow existing admin patterns for association management (see album_artists, song_artists)
- Use existing category autocomplete or select pattern
- Maintain counter_cache for item_count

### Required Outputs
- Updated view files
- New routes for category_items
- Controller actions for add/remove
- Passing tests

### Sub-Agent Plan
1) codebase-pattern-finder → analyze album_artists/song_artists patterns
2) Implement nested routes and controller
3) Update show views with category sections
4) Write tests
5) technical-writer → update documentation

### Test Seed / Fixtures
- Use existing category and album/song fixtures

---

## Implementation Notes (living)
- Approach taken:
- Important decisions:

### Key Files Touched (paths only)
- `app/views/admin/music/albums/show.html.erb` (modify)
- `app/views/admin/music/songs/show.html.erb` (modify)
- `app/controllers/admin/music/category_items_controller.rb` (new or extend)
- `config/routes.rb` (modify)
- `test/controllers/admin/music/category_items_controller_test.rb` (new)

### Challenges & Resolutions
-

### Deviations From Plan
-

## Acceptance Results
- Date, verifier, artifacts (screenshots/links):

## Future Improvements
- Bulk category assignment from index pages
- Category suggestions based on existing associations
- Auto-categorization via AI

## Related PRs
-

## Documentation Updated
- [ ] Class docs for relevant controllers
