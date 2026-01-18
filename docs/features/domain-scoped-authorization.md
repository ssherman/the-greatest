# Domain-Scoped Authorization

## Overview
The Greatest uses a domain-scoped authorization system that allows granular permission control across media domains (music, games, books, movies). This enables contractors and staff to have specific access levels per domain without accessing other domains.

## Key Concepts

### Global Roles (User.role)
- **admin**: Super-admin with full access to all domains and all actions
- **editor**: Full read/write access to all domains (backward compatible)
- **user**: Regular user with no admin access unless granted domain roles

### Domain Roles (DomainRole)
Users can be granted domain-specific permissions via the `domain_roles` table:

| Level | Read | Write | Delete | Manage |
|-------|------|-------|--------|--------|
| viewer | Yes | No | No | No |
| editor | Yes | Yes | No | No |
| moderator | Yes | Yes | Yes | No |
| admin | Yes | Yes | Yes | Yes |

### Permission Hierarchy
1. **Global Admin** - Bypasses all checks, full access everywhere
2. **Global Editor** - Bypasses domain checks, full read/write access
3. **Domain Admin** - Full access within their domain including manage actions
4. **Domain Moderator** - Read/write/delete within domain
5. **Domain Editor** - Read/write within domain
6. **Domain Viewer** - Read-only within domain

## Architecture

### Authorization Flow
```
Request → Admin::BaseController#authenticate_admin!
          ├─ Global admin/editor? → Allow
          └─ Has domain role? → Allow
              └─ No access → Redirect with error

Action → Pundit Policy (e.g., Music::AlbumPolicy)
          ├─ global_role? → Allow (read/write/delete)
          ├─ domain_role.can_*? → Check permission level
          └─ manage? → Only global_admin or domain_admin
```

### Key Components

**Models:**
- `User` - Has many domain_roles, helper methods for permission checks
- `DomainRole` - Belongs to user, domain/permission_level enums

**Policies:**
- `ApplicationPolicy` - Base policy with global_role? and domain_role checks
- `Music::AlbumPolicy`, `Music::ArtistPolicy`, `Music::SongPolicy` - Domain implementations

**Controllers:**
- `Admin::BaseController` - `authenticate_admin!` checks access
- `Admin::DomainRolesController` - CRUD for managing user domain roles (global admin only)

## Usage

### Granting Domain Access
```ruby
# Grant editor access to music domain
user.domain_roles.create!(domain: :music, permission_level: :editor)

# Grant viewer access to games domain
user.domain_roles.create!(domain: :games, permission_level: :viewer)
```

### Checking Permissions
```ruby
# In a controller
authorize @album  # Uses Pundit policy

# In a view
<% if current_user_can_write? %>
  <%= link_to "Edit", edit_admin_album_path(@album) %>
<% end %>

# Direct check
user.can_write_in_domain?("music")  # => true/false
```

### Managing Domain Roles (Admin UI)
Navigate to `/admin/users/:user_id/domain_roles` to:
- View user's current domain roles
- Grant new domain access
- Update permission levels
- Revoke domain access

## Related Documentation
- `docs/models/domain_role.md` - DomainRole model
- `docs/models/user.md` - User model with domain role methods
- `docs/policies/application_policy.md` - Base policy
- `docs/policies/music/` - Music domain policies
