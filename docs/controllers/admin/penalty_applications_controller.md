# Admin::PenaltyApplicationsController

**Path**: `app/controllers/admin/penalty_applications_controller.rb`

## Purpose

Generic admin controller for managing PenaltyApplication join table records that connect RankingConfigurations to Penalties with a configurable value (0-100 percentage). This cross-domain controller works for all ranking configuration types (Albums, Songs, and future Books/Movies/Games configurations), excluding Artists which use a different calculation method.

## Inheritance

```ruby
class Admin::PenaltyApplicationsController < Admin::BaseController
```

Inherits from `Admin::BaseController` which provides:
- Authentication enforcement (admin/editor roles)
- Base admin layout
- Common admin helpers

## Key Features

- **Generic/Cross-Domain**: Works across all media types (Music, Books, Movies, Games)
- **Value-Based**: Each penalty application includes a configurable percentage value (0-100)
- **Edit Support**: Unlike list_penalties, supports updating the value after creation
- **Modal-Based UI**: All CRUD operations via Turbo-powered modals
- **Real-Time Updates**: Turbo Streams for instant UI updates
- **Media Type Validation**: Enforces compatibility between penalty types and configuration types

## Actions

### `index`

Lists all penalty applications for a ranking configuration.

**Method**: GET
**Path**: `/admin/ranking_configuration/:ranking_configuration_id/penalty_applications`
**Parameters**: `ranking_configuration_id` (URL param)
**Authorization**: Admin/Editor
**Layout**: None (turbo frame partial)
**Response**: Renders penalty applications table with lazy loading

**Query Optimization**:
- Eager loads `:penalty` to prevent N+1 queries
- Orders by penalty name alphabetically

### `create`

Creates a new penalty application linking a penalty to a ranking configuration with a value.

**Method**: POST
**Path**: `/admin/ranking_configuration/:ranking_configuration_id/penalty_applications`
**Parameters**:
- `ranking_configuration_id` (URL param)
- `penalty_application[penalty_id]` (required)
- `penalty_application[value]` (required, integer 0-100)

**Authorization**: Admin/Editor
**Validations**:
- Value must be between 0-100 (inclusive)
- Penalty must not already be applied to this configuration
- Penalty media type must be compatible with configuration media type

**Success Response** (Turbo Stream):
1. Flash message replacement (success)
2. Penalty applications list replacement (updated data)
3. Add modal replacement (refreshed available penalties)

**Error Response** (Turbo Stream):
- Flash message replacement (error details)
- Status: 422 Unprocessable Entity

### `edit`

Renders edit modal for updating a penalty application's value.

**Method**: GET
**Path**: `/admin/penalty_applications/:id/edit`
**Parameters**: `id` (penalty_application)
**Authorization**: Admin/Editor
**Layout**: None (modal partial)
**Response**: Renders edit modal with current value pre-filled

**UI Constraints**:
- Penalty name displayed as read-only (cannot change which penalty is applied)
- Only value field is editable

### `update`

Updates the value of an existing penalty application.

**Method**: PATCH
**Path**: `/admin/penalty_applications/:id`
**Parameters**:
- `id` (penalty_application)
- `penalty_application[value]` (required, integer 0-100)

**Authorization**: Admin/Editor
**Validations**:
- Value must be between 0-100 (inclusive)
- Note: Penalty ID is NOT allowed in update params (penalty cannot be changed)

**Success Response** (Turbo Stream):
1. Flash message replacement (success)
2. Penalty applications list replacement (updated data)

**Error Response** (Turbo Stream):
- Flash message replacement (error details)
- Status: 422 Unprocessable Entity

### `destroy`

Removes a penalty application from a ranking configuration.

**Method**: DELETE
**Path**: `/admin/penalty_applications/:id`
**Parameters**: `id` (penalty_application)
**Authorization**: Admin/Editor

**Success Response** (Turbo Stream):
1. Flash message replacement (success)
2. Penalty applications list replacement (without deleted penalty)
3. Add modal replacement (refreshed to include newly available penalty)

## Private Methods

### `set_ranking_configuration`

Before action for index and create actions.
Loads ranking configuration from `params[:ranking_configuration_id]`.

### `set_penalty_application`

Before action for edit, update, and destroy actions.
Loads penalty application from `params[:id]`.

### `create_penalty_application_params`

Strong parameters for create action.
Permits: `penalty_id`, `value`

### `update_penalty_application_params`

Strong parameters for update action.
Permits: `value` only (penalty cannot be changed after creation)

### `redirect_path`

Determines appropriate redirect path based on ranking configuration STI type.

**Return values**:
- `Music::Albums::RankingConfiguration` → `admin_albums_ranking_configuration_path`
- `Music::Songs::RankingConfiguration` → `admin_songs_ranking_configuration_path`
- Default → `music_root_path`

## Media Type Compatibility

**Validation Rules** (enforced by PenaltyApplication model):
- `Global::Penalty` → Works with ANY ranking configuration type
- `Music::Penalty` → Only works with `Music::*::RankingConfiguration`
- `Books::Penalty` → Only works with `Books::RankingConfiguration`
- `Movies::Penalty` → Only works with `Movies::RankingConfiguration`
- `Games::Penalty` → Only works with `Games::RankingConfiguration`

## Turbo Frame/Stream IDs

**Frame IDs**:
- `penalty_applications_list` - Main content frame for penalty applications table

**Modal IDs**:
- `add_penalty_to_configuration_modal` - Container div
- `add_penalty_to_configuration_modal_dialog` - Dialog element
- `edit_penalty_application_modal` - Container div
- `edit_penalty_application_modal_dialog` - Dialog element

**Target Frame**:
- Both modal forms target `penalty_applications_list` on successful submission

## Related Files

**Models**:
- `app/models/penalty_application.rb` - Join model with validations
- `app/models/penalty.rb` - Penalty base model
- `app/models/ranking_configuration.rb` - Configuration base model

**Views**:
- `app/views/admin/penalty_applications/index.html.erb` - Penalty applications table
- `app/views/admin/penalty_applications/edit.html.erb` - Edit modal trigger

**Components**:
- `app/components/admin/add_penalty_to_configuration_modal_component.rb` - Add modal
- `app/components/admin/edit_penalty_application_modal_component.rb` - Edit modal

**Integration Points**:
- `app/views/admin/music/albums/ranking_configurations/show.html.erb` - Penalty applications section
- `app/views/admin/music/songs/ranking_configurations/show.html.erb` - Penalty applications section
- `app/controllers/admin/music/ranking_configurations_controller.rb` - Eager loads penalty_applications

**Tests**:
- `test/controllers/admin/penalty_applications_controller_test.rb` - 19 controller tests
- `test/components/admin/add_penalty_to_configuration_modal_component_test.rb` - 5 component tests
- `test/components/admin/edit_penalty_application_modal_component_test.rb` - 4 component tests

## Usage Example

```ruby
# User visits album ranking configuration show page
# → Section displays: "Penalty Applications (2)"
# → Lazy-loaded frame fetches index action

# User clicks "+ Add Penalty" button
# → Opens modal via add_penalty_to_configuration_modal_dialog.showModal()
# → Dropdown shows available penalties (Global + Music, excluding already applied)
# → User selects "Low Voter Count" and enters value "75"
# → Form submits to create action

# Success turbo stream response:
# 1. Flash: "Penalty attached successfully."
# 2. List updates showing: "Low Voter Count | Global | Static | 75%"
# 3. Modal refreshes (penalty now excluded from dropdown)

# User clicks edit icon on penalty application
# → GET /admin/penalty_applications/:id/edit
# → Modal opens showing penalty name (read-only) and current value 75
# → User changes value to 50 and submits

# Update turbo stream response:
# 1. Flash: "Penalty application updated successfully."
# 2. List updates showing: "Low Voter Count | Global | Static | 50%"
```

## Key Differences from ListPenaltiesController

1. **Parent Model**: RankingConfiguration vs List
2. **Value Field**: Includes value (0-100) with validation
3. **Edit/Update**: Supports editing value (list_penalties does not)
4. **Penalty Types**: Works with both static AND dynamic penalties (list_penalties only static)
5. **Turbo Frame IDs**: Different frame/modal identifiers
6. **Button Label**: "Add Penalty" vs "Attach Penalty"

## Implementation Notes

**Created**: 2025-11-15 (Phase 12)
**Pattern Source**: `Admin::ListPenaltiesController` (Phase 11)
**Reusability**: Generic controller ready for Books/Movies/Games configurations in future phases
