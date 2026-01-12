# 112 - Custom Admin Music Categories

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-10
- **Started**: 2026-01-10
- **Completed**: 2026-01-12
- **Developer**: Claude Opus 4.5

## Overview
Implement a custom admin interface for Music::Category CRUD operations with index (with search), show, new, edit pages. This follows the existing custom admin patterns established in Phase 1-14 and will replace the Avo-based category management for the music domain.

**Non-goals:**
- No actions system (no bulk actions, execute actions, or index actions needed for categories)
- No OpenSearch integration (SQL ILIKE search is sufficient for category dataset size)
- No other domain categories (games, movies, books) - music only for now

## Context & Links
- Related tasks: Spec 020 (Categories Model), Spec 072 (Custom Admin Phase 1 - Artists)
- Source files: `app/models/music/category.rb`, `app/models/category.rb`
- Existing admin patterns: `app/controllers/admin/music/artists_controller.rb`

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes required. Using existing `Music::Category` model with STI from base `Category` model.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/categories | Index with search & pagination | `q` (search), `sort`, `page` | admin/editor |
| GET | /admin/categories/:id | Show category details | | admin/editor |
| GET | /admin/categories/new | New category form | | admin/editor |
| POST | /admin/categories | Create category | `music_category[name, description, category_type, parent_id]` | admin/editor |
| GET | /admin/categories/:id/edit | Edit category form | | admin/editor |
| PATCH | /admin/categories/:id | Update category | `music_category[name, description, category_type, parent_id]` | admin/editor |
| DELETE | /admin/categories/:id | Soft delete category | | admin/editor |

> Source of truth: `config/routes.rb` (lines 44-194)

### Schemas (JSON)
Not applicable - standard Rails form submissions.

### Behaviors (pre/postconditions)

**Index Page:**
- Preconditions: User is admin or editor
- Postconditions: Returns paginated list of `Music::Category.active` (non-deleted)
- Search: SQL ILIKE on `name` field
- Default sort: by `name` ascending

**Create:**
- Preconditions: Valid name (required), valid category_type enum
- Postconditions: New Music::Category created with slug auto-generated
- Failure: Re-render form with validation errors

**Update:**
- Preconditions: Category exists and is not soft-deleted
- Postconditions: Category attributes updated, slug regenerated if name changed
- Failure: Re-render form with validation errors

**Delete:**
- Preconditions: Category exists
- Postconditions: Category soft-deleted (`deleted: true`)
- Note: Associated CategoryItems remain for data integrity

**Edge cases & failure modes:**
- Duplicate name: Handled by validation (not unique, but FriendlyId slug scoped by type)
- Parent self-reference: Category cannot be its own parent (validation)
- Delete category with items: Soft delete succeeds, items remain associated

### Non-Functionals
- Performance: Eager load parent category on index (`includes(:parent)`)
- No N+1: Item counts use counter_cache (`item_count` column)
- Security: Admin/editor role required (via `Admin::BaseController#authenticate_admin!`)
- Responsiveness: Follow DaisyUI responsive patterns from existing admin

## Acceptance Criteria
- [x] Index page displays categories in a table with columns: Name, Category Type, Item Count, Parent, Actions
- [x] Search input filters categories by name (ILIKE search)
- [x] Pagination works with 25 items per page
- [x] Sortable columns: Name, Category Type, Item Count
- [x] Show page displays: Name, Description, Category Type, Parent, Item Count, Slug, Created/Updated timestamps
- [x] Show page displays counts breakdown: Albums count, Artists count, Songs count
- [x] New/Edit form has fields: Name (required), Description (textarea), Category Type (select), Parent (select dropdown)
- [x] Form validation errors display correctly
- [x] Delete uses soft deletion (sets `deleted: true`)
- [x] Sidebar link for Categories is now active and navigates to index
- [x] All pages are responsive (mobile/tablet/desktop)
- [x] Authorization blocks non-admin/non-editor users

### Golden Examples
```text
Input: Search "rock" on index page
Output: Table showing categories with "rock" in name (e.g., "Rock", "Hard Rock", "Progressive Rock")

Input: Create category with name "Alternative", type "genre"
Output: New Music::Category created with slug "alternative", redirects to show page

Input: Delete category "Jazz"
Output: Category soft-deleted, no longer appears in index, redirects to index with success flash
```

### Optional Reference Snippet (<=40 lines, non-authoritative)
```ruby
# app/controllers/admin/music/categories_controller.rb
class Admin::Music::CategoriesController < Admin::Music::BaseController
  before_action :set_category, only: [:show, :edit, :update, :destroy]

  def index
    @categories = Music::Category.active.includes(:parent)

    if params[:q].present?
      @categories = @categories.search_by_name(params[:q])
    end

    @categories = @categories.order(sortable_column(params[:sort]))
    @pagy, @categories = pagy(@categories, items: 25)
  end

  def show; end

  def new
    @category = Music::Category.new
  end

  def create
    @category = Music::Category.new(category_params)
    if @category.save
      redirect_to admin_category_path(@category), notice: "Category created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # ... edit, update, destroy follow same pattern
end
```

---

## Agent Hand-Off

### Constraints
- Follow existing admin patterns from `Admin::Music::ArtistsController`
- Use DaisyUI components consistent with existing admin UI
- Use `Admin::SearchComponent` ViewComponent for search
- Use Pagy for pagination
- No new gems or dependencies
- Do not add OpenSearch indexing for categories

### Required Outputs
- Updated files (paths listed in "Key Files Touched")
- Passing tests demonstrating Acceptance Criteria
- Updated: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder -> verify Admin::Music::ArtistsController patterns
2) Implement controller following ArtistsController pattern
3) Implement views following artists views pattern
4) Update routes to add categories resource
5) Update sidebar to activate Categories link
6) Write controller tests
7) technical-writer -> update documentation

### Test Seed / Fixtures
- Use existing category fixtures if available
- Minimal fixtures: 3-5 categories with different types and parent relationships

---

## Implementation Notes (living)
- Approach taken: Followed Admin::Music::ArtistsController pattern closely. Used Rails generator for controller/tests (per dev-core-values.md), then implemented CRUD following existing patterns.
- Important decisions:
  - Used SQL ILIKE search via `search_by_name` scope instead of OpenSearch (dataset is small)
  - Added `:finders` to FriendlyId config in Category model to enable `find` by slug
  - Show page includes albums_count, artists_count, songs_count statistics
  - Parent dropdown excludes current category to prevent self-reference
  - Added `soft_delete!` instance method to Category model for explicit soft delete behavior

### Key Files Touched (paths only)
- `app/controllers/admin/music/categories_controller.rb` (new)
- `app/views/admin/music/categories/index.html.erb` (new)
- `app/views/admin/music/categories/show.html.erb` (new)
- `app/views/admin/music/categories/new.html.erb` (new)
- `app/views/admin/music/categories/edit.html.erb` (new)
- `app/views/admin/music/categories/_form.html.erb` (new)
- `app/views/admin/music/categories/_table.html.erb` (new)
- `app/views/admin/shared/_sidebar.html.erb` (modify - activate Categories link)
- `config/routes.rb` (modify - add categories resource at line 191)
- `app/models/category.rb` (modify - added `:finders` to FriendlyId config, added `soft_delete!` method)
- `test/controllers/admin/music/categories_controller_test.rb` (new - 31 tests)

### Challenges & Resolutions
- FriendlyId find by slug wasn't working initially. Fixed by adding `:finders` module to Category model's FriendlyId config.
- Test failure on update redirect due to slug change. Fixed by reloading category before asserting redirect path.

### Deviations From Plan
- Modified `app/models/category.rb` to add `:finders` to FriendlyId config (not in original plan but required for slug-based find)

## Acceptance Results
- Date: 2026-01-12
- Verifier: Claude Opus 4.5
- All 31 controller tests pass
- Full test suite (2864 tests) passes with 0 failures

## Future Improvements
- Add bulk soft-delete action if needed
- Add category merge functionality in admin (currently only via service objects)
- Add filter by category_type
- Add link to associated albums/artists/songs from show page

## Related PRs
- (pending commit)

## Documentation Updated
- [x] Class docs for `Admin::Music::CategoriesController` at `docs/controllers/admin/music/categories_controller.md`
