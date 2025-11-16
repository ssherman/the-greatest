# Admin::RankedListsController

## Summary
Generic admin controller for managing RankedList join table records (connecting RankingConfigurations to Lists). Provides CRUD operations for attaching/detaching lists from ranking configurations with real-time Turbo Stream updates. Works cross-domain for all ranking configuration types (Music::Albums, Music::Songs, Books, Movies, Games).

## Actions

### `index`
Lists all ranked lists for a given ranking configuration
- **Path**: `GET /admin/ranking_configuration/:ranking_configuration_id/ranked_lists`
- **Parameters**: `ranking_configuration_id` (Integer) - ID of the ranking configuration
- **Response**: Partial HTML (no layout) rendered in turbo frame
- **Context**: Lazy-loaded turbo frame on ranking configuration show pages
- **Pagination**: 25 items per page via pagy
- **Ordering**: By weight DESC
- **Eager Loading**: Includes `list: :submitted_by` to prevent N+1

### `show`
Displays detailed calculated weight breakdown for a single ranked list
- **Path**: `GET /admin/ranked_lists/:id`
- **Parameters**: `id` (Integer) - RankedList ID
- **Response**: Full page with music/admin layout
- **Layout**: Uses `music/admin` layout (not application layout)
- **Display**: Friendly formatted calculated_weight_details with color-coded penalty badges
- **Handles NULL**: Shows "Weight not yet calculated" message when calculated_weight_details is NULL
- **Eager Loading**: Includes `ranking_configuration`, `list: :submitted_by`

### `create`
Adds a list to a ranking configuration
- **Path**: `POST /admin/ranking_configuration/:ranking_configuration_id/ranked_lists`
- **Parameters**:
  - `ranking_configuration_id` (Integer) - ID of the ranking configuration
  - `ranked_list[list_id]` (Integer) - ID of the list to add
- **Response**: Turbo Stream with 3 replacements (flash, ranked_lists_list, modal)
- **Validations**:
  - Prevents duplicate list assignments
  - Enforces media type compatibility (e.g., Music::Albums::List only with Music::Albums::RankingConfiguration)
- **Side Effects**: Creates RankedList record with NULL weight (calculated by background job)
- **Success**: Flash notice "List added successfully."
- **Failure**: Flash error with validation message (status 422)

### `destroy`
Removes a list from a ranking configuration
- **Path**: `DELETE /admin/ranked_lists/:id`
- **Parameters**: `id` (Integer) - RankedList ID
- **Response**: Turbo Stream with 3 replacements (flash, ranked_lists_list, modal)
- **Side Effects**: Destroys RankedList record
- **Success**: Flash notice "List removed successfully."

## Authorization
- **Inheritance**: Inherits from `Admin::BaseController`
- **Required Role**: Admin or Editor
- **Failure**: Redirects to domain root path (music_root_path, books_root_path, etc.)

## Strong Parameters
Whitelists only `list_id` for create action:
```ruby
def ranked_list_params
  params.require(:ranked_list).permit(:list_id)
end
```

## Redirect Logic
Dynamic redirect path based on ranking configuration STI type:
- `Music::Albums::*` → `admin_albums_ranking_configuration_path`
- `Music::Songs::*` → `admin_songs_ranking_configuration_path`
- Other types → `music_root_path` (fallback)

## Turbo Stream Replacements

### Create/Destroy Success
Replaces 3 elements:
1. **flash**: Success/error message
2. **ranked_lists_list**: Updated table with new/removed list
3. **add_list_to_configuration_modal**: Refreshed modal with updated available lists

### Failure
Replaces only flash element with error message

## Performance Considerations
- **N+1 Prevention**: Eager loads associations in index and show actions
- **Lazy Loading**: Index is lazy-loaded via turbo frame on ranking config pages
- **Pagination**: Limits to 25 items per page

## Security
- **Authorization**: Enforced via Admin::BaseController
- **CSRF**: Rails default protection via form helpers
- **Parameter Filtering**: Strong params whitelist
- **SQL Injection**: ActiveRecord parameterization

## Related Files
- **Model**: `app/models/ranked_list.rb`
- **Component**: `app/components/admin/add_list_to_configuration_modal_component.rb`
- **Views**:
  - `app/views/admin/ranked_lists/index.html.erb`
  - `app/views/admin/ranked_lists/show.html.erb`
- **Tests**: `test/controllers/admin/ranked_lists_controller_test.rb`
- **Pattern Source**: `app/controllers/admin/penalty_applications_controller.rb`
