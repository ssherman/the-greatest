# Music::AlbumPolicy

## Summary
Pundit policy for Music::Album authorization. Extends ApplicationPolicy with music domain and album-specific action permissions.

## Domain
`"music"`

## Inherited Methods
All methods from `ApplicationPolicy` are available with domain set to "music":
- `index?`, `show?` - Read access
- `create?`, `new?`, `update?`, `edit?` - Write access
- `destroy?` - Delete access
- `manage?` - System actions (admin only)

## Additional Methods

### `#import?`
Authorization for importing albums from external sources (MusicBrainz).
- Returns: Boolean (delegates to `manage?`)
- Requires: Global admin OR domain admin

### `#bulk_action?`
Authorization for bulk operations on multiple albums.
- Returns: Boolean (true if global_role? or domain_role.can_delete?)
- Requires: Global admin/editor OR domain moderator+

### `#execute_action?`
Authorization for executing custom admin actions on albums.
- Returns: Boolean (true if global_role? or domain_role.can_write?)
- Requires: Global admin/editor OR domain editor+

## Scope
Inherits from `ApplicationPolicy::Scope` with domain set to "music".

## Related Classes
- `ApplicationPolicy` - Base policy
- `Music::Album` - The model being authorized
- `Admin::Music::AlbumsController` - Controller using this policy

## Usage Example

```ruby
# In controller
def bulk_action
  authorize Music::Album, :bulk_action?
  # perform bulk operation
end

def execute_action
  authorize @album
  # custom action
end
```
