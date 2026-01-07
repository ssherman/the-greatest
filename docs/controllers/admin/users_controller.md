# Admin::UsersController

## Summary
Admin controller for managing User accounts across all domains. Provides CRUD operations (except create) for user management. Users are created via Firebase authentication, so this controller handles viewing, editing, and deleting existing users only.

## Purpose
- View all users with email search functionality
- Display detailed user information including authentication and activity data
- Edit user profile and access control settings
- Delete users with proper cascade handling
- Admin-only access (editors cannot manage users)

## Inheritance
- Inherits from: `Admin::BaseController`
- Uses layout: `music/admin`

## Authorization

### `require_admin_role!` (before_action)
**Important:** Unlike other admin controllers that allow both admin and editor roles, this controller requires admin role only.

**Behavior:**
- Redirects to domain-specific root path if user lacks admin role
- Sets flash alert: "Access denied. Admin role required."

**Authorization Logic:**
```ruby
current_user&.admin?
```

**Why admin-only:** User management is a sensitive operation that should be restricted to administrators.

## Actions

### `index`
Lists all users with optional email search and pagination.

**Parameters:**
- `q` (optional): Email search query (case-insensitive partial match)
- `page` (optional): Pagination page number

**Features:**
- Uses ILIKE for case-insensitive email search
- Ordered by `created_at DESC` (newest first)
- 25 users per page via Pagy
- Turbo Frame search via `Admin::SearchComponent`

### `show`
Displays detailed user information organized in cards.

**Displayed Information:**
- Profile: photo, email, display_name, name, role
- Authentication: provider, email_verified, original_signup_domain, confirmed_at
- Activity: sign_in_count, last_sign_in_at
- Billing: stripe_customer_id (if present)
- Metadata: id, created_at, updated_at
- Related data counts: ranking_configurations, penalties, ai_chats, submitted_lists, submitted_external_links

### `edit`
Renders the edit form for user attributes.

### `update`
Updates user with permitted parameters.

**Permitted Parameters:**
- `email` - User's email address (required, unique)
- `display_name` - Public display name
- `name` - Full name
- `role` - Access level (user, editor, admin)
- `stripe_customer_id` - Stripe customer identifier

**Success:** Redirects to show page with success notice
**Failure:** Re-renders edit form with validation errors (422 status)

### `destroy`
Deletes user and triggers cascade deletions.

**Cascade Behavior (via User model associations):**
- `ranking_configurations` - destroyed
- `penalties` - destroyed
- `ai_chats` - destroyed
- `submitted_lists` - nullified (lists remain, `submitted_by_id` set to NULL)
- `submitted_external_links` - nullified (links remain, `submitted_by_id` set to NULL)

**Success:** Redirects to index with success notice

## Routes

| Verb | Path | Action |
|------|------|--------|
| GET | /admin/users | index |
| GET | /admin/users/:id | show |
| GET | /admin/users/:id/edit | edit |
| PATCH/PUT | /admin/users/:id | update |
| DELETE | /admin/users/:id | destroy |

**Note:** No `new` or `create` routes - users are created via Firebase authentication.

## Views

### Index (`index.html.erb`)
- Page header with title and description
- Search card using `Admin::SearchComponent`
- Users table wrapped in Turbo Frame for search updates

### Table Partial (`_table.html.erb`)
- Columns: ID, Email, Display Name, Role, Last Sign In, Actions
- Role badges: admin (red), editor (yellow), user (gray)
- Action buttons: View, Edit, Delete
- Pagination with search query preserved
- Empty state with contextual message

### Show (`show.html.erb`)
- Back button to index
- Edit and Delete buttons in header
- 3-column grid layout (2 main + 1 sidebar)
- Multiple cards for organized information
- Related data counts in sidebar
- Deletion warning about cascade behavior

### Edit (`edit.html.erb`)
- Back button to show page
- Renders shared form partial

### Form Partial (`_form.html.erb`)
- Error summary with per-field errors
- Account Information card: email, display_name, name
- Access Control card: role select dropdown
- Billing card: stripe_customer_id
- Cancel (returns to show) and Submit buttons

## Related Classes
- `Admin::BaseController` - Parent class with shared admin functionality
- `User` - Model being managed
- `Admin::SearchComponent` - ViewComponent for search input
- Pagy - Pagination

## File Location
`app/controllers/admin/users_controller.rb`

## View Files
- `app/views/admin/users/index.html.erb`
- `app/views/admin/users/_table.html.erb`
- `app/views/admin/users/show.html.erb`
- `app/views/admin/users/edit.html.erb`
- `app/views/admin/users/_form.html.erb`

## Tests
`test/controllers/admin/users_controller_test.rb` - 15 tests covering:
- All CRUD actions
- Search functionality
- Authorization (admin-only)
- Validation errors
