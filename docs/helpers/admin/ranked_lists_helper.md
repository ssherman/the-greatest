# Admin::RankedListsHelper

## Summary
Helper module for rendering ranked list views in the admin interface. Provides badge color coding for penalty values on the ranked list show page.

## Public Methods

### `penalty_badge_class(penalty_value)`
Returns DaisyUI badge class based on penalty severity
- **Parameters**:
  - `penalty_value` (Float) - Penalty percentage value
- **Returns**: String - DaisyUI badge class name
- **Usage**: Applied to penalty badges on ranked list show page

**Color Coding**:
- **Green** (`badge-success`): penalty < 10% (low impact)
- **Yellow** (`badge-warning`): penalty 10-24% (moderate impact)
- **Red** (`badge-error`): penalty ≥ 25% (high impact)

**Example**:
```erb
<% @ranked_list.calculated_weight_details['penalties'].each do |penalty| %>
  <div class="badge <%= penalty_badge_class(penalty['value']) %> badge-lg">
    <%= penalty['penalty_name'] %>: <%= number_with_precision(penalty['value'], precision: 2) %>%
  </div>
<% end %>
```

**Test Coverage**:
- Returns `badge-success` for penalty value 5.0
- Returns `badge-warning` for penalty value 15.0
- Returns `badge-error` for penalty value 30.0

## Usage Context
Used exclusively on the ranked list show page (`app/views/admin/ranked_lists/show.html.erb`) to color-code penalty badges in the "Penalties Applied" card section.

## Related Files
- **View**: `app/views/admin/ranked_lists/show.html.erb`
- **Tests**: `test/helpers/admin/ranked_lists_helper_test.rb`
- **Pattern Source**: `app/helpers/music/lists_helper.rb:2-6`

## Design Rationale
Color coding provides quick visual indication of penalty severity:
- **Green badges** indicate minor penalties that have little impact on final weight
- **Yellow badges** indicate moderate penalties worth reviewing
- **Red badges** indicate significant penalties that substantially reduce list weight

This helps administrators quickly identify which penalties are most impactful when reviewing calculated weights.
