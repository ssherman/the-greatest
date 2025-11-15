# Admin::ListPenaltiesController

## Summary
Generic cross-domain controller for managing ListPenalty join table associations. Handles attaching and detaching penalties from lists across all media types (Music, Books, Movies, Games). Uses Turbo Streams for real-time UI updates without full page reloads.

## Inheritance
Inherits from `Admin::BaseController`, which provides admin authentication and authorization.

## Actions

### `#index`
Displays all penalties currently attached to a list.
- **Before Action**: `set_list`
- **Response**: Renders without layout (partial for Turbo Stream replacement)
- **Query**: Eager loads penalties, orders by penalty name
- **Usage**: Called via Turbo Stream to refresh the penalties list

### `#create`
Attaches a new penalty to a list.
- **Before Action**: `set_list`
- **Parameters**: `penalty_id` (via `list_penalty_params`)
- **Response**:
  - Success: Returns 3 Turbo Streams (flash notice, updated penalties list, refreshed modal)
  - Failure: Returns error flash via Turbo Stream with `:unprocessable_entity` status
- **Side Effects**: Reloads list after save to ensure fresh data
- **Validation**: Enforced by ListPenalty model (compatibility, static-only, uniqueness)

### `#destroy`
Detaches a penalty from a list.
- **Before Action**: `set_list_penalty`
- **Response**: Returns 3 Turbo Streams (flash notice, updated penalties list, refreshed modal)
- **Side Effects**: Reloads list after destroy to ensure fresh data

## Private Methods

### `#set_list`
Finds and sets `@list` from `params[:list_id]`.
- **Used By**: `index`, `create` actions

### `#set_list_penalty`
Finds and sets `@list_penalty` from `params[:id]`.
- **Used By**: `destroy` action
- **Note**: Also sets `@list` from the penalty's association

### `#list_penalty_params`
Strong parameters for ListPenalty creation.
- **Permitted**: `penalty_id`
- **Returns**: Hash with whitelisted attributes

### `#redirect_path`
Determines the correct redirect path based on list STI type.
- **Logic**: Pattern matches on `@list.type` to route to appropriate admin show page
- **Supported Types**:
  - `Music::Albums::*` → `admin_albums_list_path`
  - `Music::Songs::*` → `admin_songs_list_path`
  - Other → `music_root_path` (fallback)
- **Returns**: String URL path

## Turbo Stream Pattern

All actions respond to both `turbo_stream` and `html` formats. The Turbo Stream responses replace three key elements:

1. **Flash Messages** (`#flash`) - Shows success/error notifications
2. **Penalties List** (`#list_penalties_list`) - Updates the displayed penalties
3. **Attach Modal** (`#attach_penalty_modal`) - Refreshes available penalties dropdown

This pattern enables real-time updates without page reloads while maintaining fallback HTML responses.

## Routes
- `GET /admin/lists/:list_id/list_penalties` → `index`
- `POST /admin/lists/:list_id/list_penalties` → `create`
- `DELETE /admin/list_penalties/:id` → `destroy`

## Dependencies
- `ListPenalty` model - Join table with validation logic
- `Admin::AttachPenaltyModalComponent` - ViewComponent for penalty selection modal
- `Admin::ListPenaltiesHelper#available_penalties` - Filters penalties by media type and excludes already attached
- Turbo Streams for reactive UI updates
- DaisyUI modal component for dialog UI

## Related Components
- `Admin::AttachPenaltyModalComponent` - Renders the penalty attachment form
- `Admin::ListPenaltiesHelper` - Provides `available_penalties(list)` helper method

## Cross-Domain Design
This controller is intentionally domain-agnostic:
- Works with any List STI type (Music::Albums::*, Music::Songs::*, Books::*, etc.)
- Penalty filtering handled by helper method based on media type
- Compatibility validation delegated to ListPenalty model
- Routing handled dynamically via `redirect_path` pattern matching
