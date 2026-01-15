# 113 - Admin Category Sections (Turbo/Lazy-Loaded)

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-12
- **Updated**: 2026-01-15
- **Started**: 2026-01-15
- **Completed**: 2026-01-15
- **Developer**: Claude

## Overview
Add turbo-frame lazy-loaded category index sections to the admin show pages for Artists and Albums. These sections should follow the established lazy-loading pattern used by other cross-domain controllers (`Admin::ListPenaltiesController`, `Admin::PenaltyApplicationsController`) and be designed for reuse across all media types (Music, Books, Games, Movies).

**Goals:**
- Turbo-frame lazy-loaded category list on Artist show page
- Turbo-frame lazy-loaded category list on Album show page
- Add/remove category functionality via modal
- Cross-domain controller design (like `ListPenaltiesController`)

**Non-goals:**
- Songs category section (can be added later using same pattern)
- Inline category creation (use Categories admin for that)
- Bulk category assignment from index pages

## Context & Links
- Related tasks: Spec 112 (Custom Admin Music Categories)
- Source files (authoritative):
  - `app/views/admin/music/albums/show.html.erb`
  - `app/views/admin/music/artists/show.html.erb`
  - `app/controllers/admin/list_penalties_controller.rb` (pattern reference)
  - `app/controllers/admin/penalty_applications_controller.rb` (pattern reference)
  - `app/models/category_item.rb`
  - `app/models/category.rb`
- External docs: [Turbo Frames](https://turbo.hotwired.dev/handbook/frames)

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes required. Uses existing `CategoryItem` polymorphic join model.

Existing relationships (see `docs/models/category_item.md`):
- `CategoryItem` belongs_to :category, counter_cache: :item_count
- `CategoryItem` belongs_to :item, polymorphic: true
- `Music::Artist` has_many :categories through :category_items
- `Music::Album` has_many :categories through :category_items

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/artists/:artist_id/category_items | Lazy-load categories list for artist | | admin/editor |
| POST | /admin/artists/:artist_id/category_items | Add category to artist | `category_id` | admin/editor |
| DELETE | /admin/category_items/:id | Remove category from item | | admin/editor |
| GET | /admin/albums/:album_id/category_items | Lazy-load categories list for album | | admin/editor |
| POST | /admin/albums/:album_id/category_items | Add category to album | `category_id` | admin/editor |

> Source of truth: `config/routes.rb`

### Behaviors (pre/postconditions)

**Index (Lazy Load):**
- Preconditions: Parent entity exists
- Postconditions: Returns HTML fragment wrapped in turbo_frame_tag
- Response: `render layout: false` for turbo-frame responses
- Query: Eager load categories with `.includes(:category)`

**Create (Add Category):**
- Preconditions: Category exists, item exists, not already associated
- Postconditions: CategoryItem created, counter_cache updated, search reindex queued
- Turbo Stream Response: Replace frame content + flash message + modal refresh
- Failure: Show error in flash, status :unprocessable_entity

**Destroy (Remove Category):**
- Preconditions: CategoryItem exists
- Postconditions: CategoryItem destroyed, counter_cache updated, search reindex queued
- Turbo Stream Response: Replace frame content + flash message + modal refresh

### Non-Functionals
- **N+1 Prevention**: Eager load with `.includes(:category)`
- **Security**: Admin/editor role required (via Admin::BaseController)
- **Performance**: Lazy loading defers category fetch until section is visible
- **UX**: Loading spinner shown while fetching, autocomplete for category selection

## Acceptance Criteria
- [ ] Artist show page has "Categories" section with lazy-loaded turbo frame
- [ ] Album show page has "Categories" section with lazy-loaded turbo frame
- [ ] Categories section shows loading spinner initially, then loads via turbo frame
- [ ] Admin can add a category via modal with autocomplete search
- [ ] Admin can remove a category with confirmation
- [ ] Category names link to admin category show page (with turbo_frame: "_top")
- [ ] Adding duplicate category shows appropriate error
- [ ] Category counter_cache (item_count) is correctly updated
- [ ] Controller is cross-domain (not namespaced under Music)
- [ ] Controller follows `ListPenaltiesController` pattern with `redirect_path`

### Golden Examples
```text
Example 1: Lazy Load
Input: User navigates to /admin/artists/123 and scrolls to Categories section
Output: GET /admin/artists/123/category_items fires, spinner replaced with category table

Example 2: Add Category
Input: Click "+ Add Category", search "Rock", select "Rock", submit
Output: CategoryItem created, modal closes, list refreshes with "Rock" row

Example 3: Remove Category
Input: Click "Remove" on "Jazz" category, confirm
Output: CategoryItem destroyed, row removed from table, flash success
```

---

## Agent Hand-Off

### Constraints
- Follow existing cross-domain patterns from `admin/list_penalties_controller.rb`
- Controller at `Admin::CategoryItemsController` (NOT under Music namespace)
- Use `redirect_path` with STI type pattern matching for routing
- Use existing `AutocompleteComponent` for category search
- Use existing `modal-form` Stimulus controller for modal interaction
- Respect snippet budget (≤40 lines per snippet)
- Do not duplicate authoritative code; link to file paths

### Required Outputs
- Updated routes in `config/routes.rb`
- New controller: `app/controllers/admin/category_items_controller.rb`
- New views: `app/views/admin/category_items/index.html.erb`
- New component: `app/components/admin/add_category_modal_component.rb`
- Updated show pages: artists/show.html.erb, albums/show.html.erb
- Passing tests for all acceptance criteria
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder → analyze list_penalties_controller + view patterns
2) codebase-analyzer → verify CategoryItem integration points
3) Implement routes and controller
4) Create index view partial
5) Create modal component
6) Update show pages with turbo frames and modals
7) Write controller tests
8) technical-writer → update documentation

### Test Seed / Fixtures
- Use existing category fixtures from `test/fixtures/categories.yml`
- Use existing artist/album fixtures

---

## Architecture Notes

### Cross-Domain Controller Pattern
Following `Admin::ListPenaltiesController` pattern exactly:

```ruby
# reference only - pattern illustration (see list_penalties_controller.rb)
class Admin::CategoryItemsController < Admin::BaseController
  before_action :set_item, only: [:index, :create]
  before_action :set_category_item, only: [:destroy]

  def index
    @category_items = @item.category_items.includes(:category).order("categories.name")
    render layout: false
  end

  def create
    @category_item = @item.category_items.build(category_item_params)
    # turbo_stream response pattern...
  end

  def destroy
    @item = @category_item.item
    @category_item.destroy!
    # turbo_stream response pattern...
  end

  private

  def set_item
    @item = if params[:artist_id]
      Music::Artist.find(params[:artist_id])
    elsif params[:album_id]
      Music::Album.find(params[:album_id])
    # Future: elsif params[:book_id], params[:movie_id], etc.
    end
  end

  def redirect_path
    case @item.class.name
    when "Music::Artist"
      admin_artist_path(@item)
    when "Music::Album"
      admin_album_path(@item)
    # Future: when "Books::Book", "Movies::Movie", etc.
    else
      root_path
    end
  end
end
```

### Routes Pattern
```ruby
# reference only - nested under each resource
namespace :admin do
  resources :artists do
    resources :category_items, only: [:index, :create], controller: "category_items"
  end
  resources :albums do
    resources :category_items, only: [:index, :create], controller: "category_items"
  end
  # Standalone destroy route (like list_penalties)
  resources :category_items, only: [:destroy]
end
```

### View Pattern
Turbo frame in show page:
```erb
<!-- reference only -->
<%= turbo_frame_tag "category_items_list", loading: :lazy,
    src: admin_artist_category_items_path(@artist) do %>
  <div class="flex justify-center py-8">
    <span class="loading loading-spinner loading-lg"></span>
  </div>
<% end %>
```

### Future Extension
When adding to Books, Movies, Games:
1. Add route: `resources :books { resources :category_items, ... }`
2. Add `params[:book_id]` check to `set_item`
3. Add `when "Books::Book"` to `redirect_path`
4. Add turbo frame to books/show.html.erb

---

## Implementation Notes (living)
- Approach taken: Followed `Admin::ListPenaltiesController` pattern exactly for cross-domain reusability
- Important decisions:
  - **Display Style**: Table format with Name, Category Type, Actions columns
  - **Add Category UX**: Autocomplete search using existing AutocompleteComponent
  - **Empty State**: Always show section with "No categories" empty state and Add button
  - **Controller Design**: Cross-domain `Admin::CategoryItemsController` following `ListPenaltiesController` pattern
  - **Search Endpoint**: Added `search` action to `CategoriesController` for autocomplete (returns JSON)

### Key Files Touched (paths only)
- `config/routes.rb` (modify - add nested routes for artists/albums, standalone destroy, search for categories)
- `app/controllers/admin/category_items_controller.rb` (new - 118 lines)
- `app/controllers/admin/music/categories_controller.rb` (modify - add search action)
- `app/views/admin/category_items/index.html.erb` (new)
- `app/components/admin/add_category_modal_component.rb` (new)
- `app/components/admin/add_category_modal_component/add_category_modal_component.html.erb` (new)
- `app/views/admin/music/artists/show.html.erb` (modify - replace static badges with turbo frame)
- `app/views/admin/music/albums/show.html.erb` (modify - replace static content with turbo frame)
- `test/controllers/admin/category_items_controller_test.rb` (new - 14 tests, 61 assertions)

### Challenges & Resolutions
- **Autocomplete needs search endpoint**: Added `search` action to `CategoriesController` with JSON response format
- **Route namespace**: Used `controller: "/admin/category_items"` to reference cross-domain controller from music namespace

### Deviations From Plan
- Songs route not added (per spec, Songs is a non-goal for this phase). Controller is forward-compatible.

## Acceptance Results
- **Date**: 2026-01-15
- **Verifier**: Claude (automated tests)
- **Test Results**: 14 tests, 61 assertions, 0 failures
- **All Admin Tests**: 607 tests pass (no regressions)

## Future Improvements
- Add Songs category section using same pattern
- Extend to Books, Games, Movies when those domains are built
- Bulk category assignment from index pages
- Category suggestions based on similar entities

## Related PRs
-

## Documentation Updated
- [ ] `docs/controllers/admin/category_items_controller.md` (new)
- [ ] Class docs for AddCategoryModalComponent
