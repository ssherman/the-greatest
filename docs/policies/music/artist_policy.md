# Music::ArtistPolicy

## Summary
Pundit policy for Music::Artist authorization. Extends ApplicationPolicy with music domain and artist-specific action permissions.

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
Authorization for importing artists from external sources (MusicBrainz).
- Returns: Boolean (delegates to `manage?`)
- Requires: Global admin OR domain admin

### `#bulk_action?`
Authorization for bulk operations on multiple artists.
- Returns: Boolean (true if global_role? or domain_role.can_delete?)
- Requires: Global admin/editor OR domain moderator+

### `#execute_action?`
Authorization for executing custom admin actions on artists.
- Returns: Boolean (true if global_role? or domain_role.can_write?)
- Requires: Global admin/editor OR domain editor+

### `#index_action?`
Authorization for index-level actions (refresh all artist rankings).
- Returns: Boolean (delegates to `manage?`)
- Requires: Global admin OR domain admin

## Scope
Inherits from `ApplicationPolicy::Scope` with domain set to "music".

## Related Classes
- `ApplicationPolicy` - Base policy
- `Music::Artist` - The model being authorized
- `Admin::Music::ArtistsController` - Controller using this policy

## Usage Example

```ruby
# In controller
def index_action
  authorize Music::Artist, :index_action?
  # refresh all rankings
end
```
