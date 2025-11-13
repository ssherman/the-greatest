# Known Issues

## Admin Interface

### Phase 6: Ranking Configurations

#### Bulk Calculate Weights - No Checkbox Selection

**Issue:** The "Bulk Calculate Weights" button on the ranking configurations index page processes ALL configurations instead of only selected ones.

**Details:**
- The index page does not implement checkbox selection for individual ranking configurations
- When the "Bulk Calculate Weights" button is clicked, it processes all Album or Song ranking configurations (depending on which index you're on)
- This is a UI/UX limitation where implementing proper checkbox selection would require a Stimulus controller

**Current Behavior:**
- Clicking "Bulk Calculate Weights" on `/admin/albums/ranking_configurations` processes ALL album ranking configurations
- Clicking "Bulk Calculate Weights" on `/admin/songs/ranking_configurations` processes ALL song ranking configurations

**Workaround:**
- Use the "Refresh Rankings" action on individual ranking configuration show pages for selective processing
- The bulk action is still useful for processing all configurations at once

**Future Enhancement:**
To implement proper checkbox selection:
1. Add checkboxes to each row in the table partial
2. Create a Stimulus controller to manage checkbox state and selection
3. Submit selected IDs with the bulk action form
4. Update the controller to handle both "all" and "selected" modes

**Impact:** Low - The current behavior is still functional and useful for processing all configurations. Individual configuration processing is available via the show page action.

**Date Identified:** 2025-11-12

**Related Files:**
- `web-app/app/controllers/admin/music/ranking_configurations_controller.rb` (index_action method)
- `web-app/app/views/admin/music/albums/ranking_configurations/index.html.erb`
- `web-app/app/views/admin/music/songs/ranking_configurations/index.html.erb`
- `web-app/app/lib/actions/admin/music/bulk_calculate_weights.rb`
