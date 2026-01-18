# Music::SongPolicy

## Summary
Pundit policy for Music::Song authorization. Extends ApplicationPolicy with music domain and song-specific action permissions.

## Domain
`"music"`

## Inherited Methods
All methods from `ApplicationPolicy` are available with domain set to "music":
- `index?`, `show?` - Read access
- `create?`, `new?`, `update?`, `edit?` - Write access
- `destroy?` - Delete access
- `manage?` - System actions (admin only)

## Additional Methods

### `#bulk_action?`
Authorization for bulk operations on multiple songs.
- Returns: Boolean (true if global_role? or domain_role.can_delete?)
- Requires: Global admin/editor OR domain moderator+

### `#execute_action?`
Authorization for executing custom admin actions on songs (merge, etc.).
- Returns: Boolean (true if global_role? or domain_role.can_write?)
- Requires: Global admin/editor OR domain editor+

## Scope
Inherits from `ApplicationPolicy::Scope` with domain set to "music".

## Related Classes
- `ApplicationPolicy` - Base policy
- `Music::Song` - The model being authorized
- `Admin::Music::SongsController` - Controller using this policy

## Usage Example

```ruby
# In controller
def execute_action
  authorize @song
  # merge songs or other action
end
```
