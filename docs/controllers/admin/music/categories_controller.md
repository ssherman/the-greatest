# Admin::Music::CategoriesController

## Summary
Admin CRUD controller for Music::Category management. Provides create, read, update, and soft-delete operations with search, sorting, and pagination.

## Purpose
- Complete CRUD operations for Music::Category records (STI subclass of Category)
- SQL ILIKE search functionality via `search_by_name` scope
- Sortable columns: name, category_type, item_count
- Pagination with Pagy (25 items per page)
- Soft delete pattern (sets `deleted: true` instead of destroying)

## Inheritance
Inherits from: `Admin::Music::BaseController`

## Before Actions
- `set_category` (only: `[:show, :edit, :update, :destroy]`)

## Routes
```ruby
# Inside domain constraint for Music
namespace :admin, module: "admin/music" do
  resources :categories
end
```

**Generated paths:**
- `admin_categories_path` → `/admin/categories`
- `admin_category_path(@category)` → `/admin/categories/:id`
- `new_admin_category_path` → `/admin/categories/new`
- `edit_admin_category_path(@category)` → `/admin/categories/:id/edit`

## Public Actions

### `index`
Lists all active categories with search, sort, and pagination.

**Parameters:**
- `q` (optional) - Search query string (uses SQL ILIKE via `search_by_name` scope)
- `sort` (optional) - Column to sort by (`name`, `category_type`, `item_count`)

**Behavior:**
- Filters to active categories only (excludes soft-deleted)
- Eager loads `:parent` association to prevent N+1 queries
- Applies search filter if `q` present
- Sorts by requested column or defaults to `name`
- Paginates with Pagy (25 items per page)

### `show`
Displays single category with association counts.

**Parameters:**
- `id` - Category ID

**Instance Variables:**
- `@category` - The category record
- `@albums_count` - Count of associated albums
- `@artists_count` - Count of associated artists
- `@songs_count` - Count of associated songs

### `new`
Renders new category form.

**Instance Variables:**
- `@category` - New Music::Category instance

### `create`
Creates new category record.

**Parameters:**
- `music_category[name]` - Required
- `music_category[description]` - Optional
- `music_category[category_type]` - Category classification
- `music_category[parent_id]` - Optional parent category ID

**Success:** Redirects to show page with notice
**Failure:** Renders new form with `:unprocessable_entity` status

### `edit`
Renders edit category form.

**Instance Variables:**
- `@category` - Loaded by `set_category` before action

### `update`
Updates existing category record.

**Parameters:** Same as `create`

**Success:** Redirects to show page with notice
**Failure:** Renders edit form with `:unprocessable_entity` status

### `destroy`
Soft-deletes category record.

**Behavior:**
- Sets `deleted: true` on the record (does not call `destroy`)
- Redirects to index with success notice

**Why Soft Delete:**
- Preserves referential integrity with existing associations
- Allows recovery of accidentally deleted categories
- Maintains historical data for reporting

## Private Methods

### `set_category`
Before action that loads the category for member actions.

```ruby
before_action :set_category, only: [:show, :edit, :update, :destroy]
```

### `category_params`
Strong parameters for create/update.

**Permitted attributes:**
- `:name` - Category name
- `:description` - Category description
- `:category_type` - Type classification
- `:parent_id` - Parent category for hierarchy

### `sortable_column(column)`
Whitelists sortable columns to prevent SQL injection.

**Whitelist:**
```ruby
{
  "name" => "categories.name",
  "category_type" => "categories.category_type",
  "item_count" => "categories.item_count DESC"
}
```

**Default:** `"categories.name"`

**Security:**
- Maps user input to known-safe column names
- Uses `Hash#fetch` with default for safety
- Never interpolates user input directly into SQL

## Model Context

### Music::Category (STI)
- Subclass of `Category` base model
- Uses Single Table Inheritance with `type` column
- Scoped to music domain items (albums, artists, songs)

### Key Scopes Used
- `active` - Filters to records where `deleted: false`
- `search_by_name(query)` - SQL ILIKE search on name column

## Dependencies
- **Pagy**: Pagination (25 items per page, via `Pagy::Backend` module)
- **Admin::Music::BaseController**: Authentication, layout, domain context

## Related Classes
- `Music::Category` - Model being managed (STI from Category)
- `Category` - Base model for all categories
- `Admin::Music::BaseController` - Parent controller

## Related Views
- `/app/views/admin/music/categories/index.html.erb`
- `/app/views/admin/music/categories/show.html.erb`
- `/app/views/admin/music/categories/new.html.erb`
- `/app/views/admin/music/categories/edit.html.erb`
- `/app/views/admin/music/categories/_form.html.erb`

## File Location
`/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/categories_controller.rb`
