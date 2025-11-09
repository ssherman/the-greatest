# Admin::BaseController

## Summary
Base controller for all admin interfaces across all domains. Provides authentication, authorization, and shared admin functionality.

## Purpose
- Enforces admin/editor role requirements for all admin routes
- Provides current_user helper for admin views
- Includes Pagy pagination backend
- Sets up domain-aware root path redirection for unauthorized access

## Inheritance
- Inherits from: `ApplicationController`
- Inherited by: `Admin::Music::BaseController`, `Admin::Movies::BaseController`, etc.

## Authentication & Authorization

### `authenticate_admin!` (before_action)
Ensures only users with admin or editor roles can access admin interfaces.

**Behavior:**
- Redirects to domain-specific root path if user is not authenticated
- Redirects to domain-specific root path if user lacks admin/editor role
- Sets flash alert: "Access denied. Admin or editor role required."

**Authorization Logic:**
```ruby
current_user&.admin? || current_user&.editor?
```

## Public Methods

### `current_user`
Returns the currently authenticated user from session.

**Returns:** `User` or `nil`

**Implementation:**
- Memoized as `@current_user`
- Looks up user by `session[:user_id]`
- Available as helper method in views

### `domain_root_path` (private)
Determines the appropriate root path for the current domain.

**Returns:** String path helper result

**Logic:**
```ruby
case current_domain
when :music then music_root_path
when :movies then movies_root_path
when :games then games_root_path
else books_root_path
end
```

**Why needed:** Multi-domain architecture requires domain-specific redirects for unauthorized access

## Dependencies
- **Pagy**: Included via `Pagy::Backend` for pagination support
- **ApplicationController**: Inherits `current_domain` helper and authentication setup
- **User model**: Role enum with `admin?`, `editor?` methods

## Usage Pattern

### Typical Admin Controller
```ruby
class Admin::Music::ArtistsController < Admin::Music::BaseController
  # Automatically includes authentication via before_action :authenticate_admin!
  # Has access to current_user helper
  # Has access to Pagy pagination

  def index
    @artists = Music::Artist.all
    @pagy, @artists = pagy(@artists, items: 25)
  end
end
```

## Multi-Domain Architecture

### Domain-Specific Inheritance Chain
```
ApplicationController
  └── Admin::BaseController (this class)
      ├── Admin::Music::BaseController
      │   └── Admin::Music::ArtistsController
      ├── Admin::Movies::BaseController
      │   └── Admin::Movies::MoviesController
      └── Admin::Books::BaseController
          └── Admin::Books::BooksController
```

### Why Domain-Specific Base Controllers
- Each domain can set its own layout (`layouts/music/admin.html.erb`)
- Domain-specific before_actions and helpers
- Allows per-domain admin customization

## Security Considerations
- **Session-based auth**: Uses Rails session from Firebase authentication
- **Role-based access**: Only admin and editor roles permitted
- **No public access**: All admin routes protected by default
- **Domain isolation**: Each domain's admin is isolated within domain constraints

## Related Classes
- `ApplicationController` - Parent class with domain detection
- `User` - Provides role enum (admin, editor, user)
- `Admin::Music::BaseController` - Domain-specific child class
- `Pagy` - Pagination gem for backend support

## File Location
`/home/shane/dev/the-greatest/web-app/app/controllers/admin/base_controller.rb`
