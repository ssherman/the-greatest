# DomainRole

## Summary
Represents a domain-scoped permission for a user. Allows granular control over which media domains (music, games, books, movies) a user can access in the admin area, and at what permission level.

## Associations
- `belongs_to :user` - The user who has this domain role

## Attributes

### `domain` (integer, enum)
The media domain this role applies to.
- `music: 0`
- `games: 1`
- `books: 2`
- `movies: 3`

### `permission_level` (integer, enum)
The level of access granted within the domain.
- `viewer: 0` - Read-only access (can view admin pages)
- `editor: 1` - Can create and update content
- `moderator: 2` - Can also delete content
- `admin: 3` - Full domain access including system actions

## Public Methods

### `#can_read?`
Returns `true` for all permission levels.
- Returns: Boolean

### `#can_write?`
Returns `true` for editor, moderator, and admin levels.
- Returns: Boolean

### `#can_delete?`
Returns `true` for moderator and admin levels.
- Returns: Boolean

### `#can_manage?`
Returns `true` for admin level only. Used for system actions like cache purging, imports, and ranking configuration.
- Returns: Boolean

## Validations
- `user_id` - Must be unique within scope of `domain` (one role per user per domain)
- `domain` - Must be present
- `permission_level` - Must be present (defaults to `viewer`)

## Indexes
- `(user_id, domain)` UNIQUE - Ensures one role per user per domain
- `(domain)` - For querying users by domain
- `(permission_level)` - For querying by permission level

## Constants
None

## Callbacks
None

## Dependencies
None

## Related Classes
- `User` - Has many domain_roles
- `ApplicationPolicy` - Base policy using domain roles for authorization
- `Music::ArtistPolicy`, `Music::AlbumPolicy`, `Music::SongPolicy` - Domain-specific policies

## Usage Examples

```ruby
# Grant a user editor access to music
user.domain_roles.create!(domain: :music, permission_level: :editor)

# Check if user can write in music domain
role = user.domain_role_for("music")
role.can_write? # => true

# Grant viewer access to games
user.domain_roles.create!(domain: :games, permission_level: :viewer)

# User can read but not write in games
user.can_write_in_domain?("games") # => false
```

## Permission Hierarchy

| Level | Read | Write | Delete | Manage |
|-------|------|-------|--------|--------|
| viewer | Yes | No | No | No |
| editor | Yes | Yes | No | No |
| moderator | Yes | Yes | Yes | No |
| admin | Yes | Yes | Yes | Yes |

**Note**: Global admin (`User.role = :admin`) and global editor (`User.role = :editor`) bypass all domain checks and have full access everywhere. The `manage?` action (imports, cache purging, rankings) requires global admin OR domain admin level.
