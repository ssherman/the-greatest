# ApplicationPolicy

## Summary
Base Pundit policy for all domain resources. Provides domain-aware authorization with global admin/editor bypass. All domain-specific policies inherit from this class.

## Attributes

### `user`
The current user being authorized.
- Type: User (can be nil)

### `record`
The record being authorized against.
- Type: ActiveRecord model or class

## Public Methods

### `#domain`
Override in subclasses to specify the domain (e.g., "music", "games").
- Returns: String or nil

### `#global_admin?`
Checks if user has global admin role.
- Returns: Boolean

### `#global_editor?`
Checks if user has global editor role.
- Returns: Boolean

### `#global_role?`
Checks if user has any global role (admin OR editor) that bypasses domain checks.
- Returns: Boolean

### `#domain_role`
Gets the user's DomainRole for this policy's domain.
- Returns: DomainRole or nil

### `#index?`
Authorization for listing records.
- Returns: Boolean (true if global_role? or domain_role.can_read?)

### `#show?`
Authorization for viewing a single record.
- Returns: Boolean (true if global_role? or domain_role.can_read?)

### `#create?` / `#new?`
Authorization for creating records.
- Returns: Boolean (true if global_role? or domain_role.can_write?)

### `#update?` / `#edit?`
Authorization for updating records.
- Returns: Boolean (true if global_role? or domain_role.can_write?)

### `#destroy?`
Authorization for deleting records.
- Returns: Boolean (true if global_role? or domain_role.can_delete?)

### `#manage?`
Authorization for system actions (imports, cache purging, rankings).
- Returns: Boolean (true if global_admin? or domain_role.can_manage?)
- Note: Global editor does NOT have manage access - only global admin or domain admin

## Scope

### `Scope#resolve`
Returns the scoped records the user can access.
- Global admin/editor: all records
- Domain access: all records
- No access: no records

## Dependencies
- Pundit gem
- DomainRole model

## Related Classes
- `DomainRole` - Domain-scoped permissions
- `User` - Has domain_roles association
- `Music::AlbumPolicy`, `Music::ArtistPolicy`, `Music::SongPolicy` - Domain implementations

## Usage Example

```ruby
# In a controller
class Admin::Music::AlbumsController < Admin::BaseController
  def index
    authorize Music::Album  # Calls Music::AlbumPolicy#index?
    @albums = policy_scope(Music::Album)
  end

  def update
    @album = Music::Album.find(params[:id])
    authorize @album  # Calls Music::AlbumPolicy#update?
    @album.update(album_params)
  end
end
```

## Authorization Matrix

| Action | Global Admin | Global Editor | Domain Admin | Domain Moderator | Domain Editor | Domain Viewer |
|--------|--------------|---------------|--------------|------------------|---------------|---------------|
| index/show | Yes | Yes | Yes | Yes | Yes | Yes |
| create/update | Yes | Yes | Yes | Yes | Yes | No |
| destroy | Yes | Yes | Yes | Yes | No | No |
| manage | Yes | No | Yes | No | No | No |
