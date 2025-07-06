# Movies::Credit

## Summary
Represents a credit/role assignment for a person in film production. Polymorphic model that can be associated with either movies or releases, supporting the complex relationships in film production.

## Associations
- `belongs_to :person, class_name: "Movies::Person"` - The individual receiving the credit
- `belongs_to :creditable, polymorphic: true` - Can be associated with Movies::Movie or Movies::Release

## Public Methods

### `#role`
Returns the credit role as a symbol
- Returns: Symbol (director, producer, screenwriter, actor, actress, etc.)

### `#character_name`
Returns the character name for acting roles
- Returns: String or nil

### `#position`
Returns the position/order within the same role
- Returns: Integer or nil

## Validations
- `person` - presence
- `creditable` - presence
- `role` - presence, inclusion in valid roles
- `position` - numericality (integer, greater than 0), allow_nil

## Scopes
- `by_role(role)` - Filter credits by specific role
- `ordered_by_position` - Order credits by position
- `for_movie(movie)` - Filter credits for a specific movie
- `for_release(release)` - Filter credits for a specific release

## Constants
None defined.

## Callbacks
None defined.

## Dependencies
- ActiveRecord for database operations
- Polymorphic associations for flexible credit assignments

## Enums
- `role` - { director: 0, producer: 1, screenwriter: 2, actor: 3, actress: 4, cinematographer: 5, editor: 6, composer: 7, production_designer: 8, costume_designer: 9, makeup_artist: 10, stunt_coordinator: 11, visual_effects: 12, sound_designer: 13, casting_director: 14, executive_producer: 15, assistant_director: 16, script_supervisor: 17 } 