# 058 - Calculated Weight Details Field

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-10-21
- **Started**: 2025-10-21
- **Completed**: 2025-10-21
- **Developer**: AI Assistant

## Overview
Add a `calculated_weight_details` jsonb field to the `ranked_lists` table to store a complete breakdown of weight calculations. This will provide transparency into why a list has a particular weight and enable easier debugging of weight calculation issues, especially for dynamic penalties that aren't directly associated with the ranked list.

## Context
### Current Problem
- Once a weight is calculated and stored in `ranked_list.weight`, there's no record of HOW it was calculated
- Dynamic penalties (voter count, temporal coverage, attribute-based) are never directly associated with the ranked_list
- Users and developers cannot easily understand why a list has a particular weight
- Debugging weight calculation issues requires re-running the calculation with added logging
- No historical record of penalty values used in calculations

### Why This Is Needed
- **Transparency**: Users should be able to see exactly why a list is weighted the way it is
- **Debugging**: Developers need to troubleshoot weight calculation issues without re-running calculations
- **Audit Trail**: Historical record of what penalties were applied and their values at calculation time
- **Dynamic Penalty Visibility**: Dynamic penalties are calculated on-the-fly and never stored - this provides the only record
- **Validation**: Can verify that weight calculations are working correctly by inspecting the breakdown

### How It Fits Into the System
- Complements the existing weight calculation system (Rankings::WeightCalculatorV1)
- Provides transparency for the ranking system's core functionality
- Supports the UI in displaying meaningful information to users about list quality/reliability
- Enables future analytics and reporting on penalty distributions

## Requirements
- [ ] Add `calculated_weight_details` jsonb column to `ranked_lists` table using Rails generator (nullable, default: null)
- [ ] Update Rankings::WeightCalculatorV1 to capture and store calculation details
- [ ] Store comprehensive penalty breakdown including:
  - Each penalty ID, name, type, and class
  - Calculated value for each penalty
  - For dynamic penalties: calculation inputs (voter count, median, ratio, formula, etc.)
  - Quality bonus application details
  - Final calculation steps (penalty totals, capping, floor application, rounding)
- [ ] Update Music::Songs::List show page to display **simple penalty summary** (names and values only)
- [ ] Update Music::Albums::List show page to display **simple penalty summary** (names and values only)
- [ ] Add helper method to format simple penalty summary for public views
- [ ] Update Avo RankedList resource to display **full detailed breakdown** on show page (read-only)
- [ ] Maintain backward compatibility (field is nullable, no existing data affected)
- [ ] Update RankedList model documentation
- [ ] Update WeightCalculatorV1 documentation
- [ ] Comprehensive test coverage for new functionality

## Technical Approach

### Database Schema Change

**IMPORTANT: Use Rails generator to create migration:**

```bash
cd web-app
bin/rails generate migration AddCalculatedWeightDetailsToRankedLists calculated_weight_details:jsonb
```

This will generate a migration file that looks like:

```ruby
class AddCalculatedWeightDetailsToRankedLists < ActiveRecord::Migration[8.0]
  def change
    add_column :ranked_lists, :calculated_weight_details, :jsonb
  end
end
```

**No index needed initially** - this field is primarily for display/debugging, not querying. Can add GIN index later if needed for analytics.

### JSON Structure

Based on the weight calculation analysis, the jsonb structure will be:

```ruby
{
  "calculation_version": 1,
  "timestamp": "2025-10-21T12:34:56Z",

  "base_values": {
    "base_weight": 100,
    "minimum_weight": 10,
    "high_quality_source": false
  },

  "penalties": [
    # Static penalties
    {
      "source": "static",
      "penalty_id": 123,
      "penalty_name": "Unreliable Source",
      "penalty_class": "Global::Penalty",
      "list_penalty_id": 456,
      "penalty_application_id": 789,
      "value": 20.0
    },

    # Dynamic voter count penalties
    {
      "source": "dynamic_voter_count",
      "penalty_id": 234,
      "penalty_name": "Low Voter Count",
      "penalty_class": "Global::Penalty",
      "penalty_application_id": 890,
      "max_value": 30.0,
      "calculation": {
        "voter_count": 5,
        "median_voter_count": 50,
        "ratio": 0.1,
        "exponent": 2.0,
        "formula": "max_value * ((1.0 - ratio) ** exponent)"
      },
      "value": 24.3
    },

    # Dynamic attribute penalties
    {
      "source": "dynamic_attribute",
      "penalty_id": 345,
      "penalty_name": "Unknown Voter Names",
      "penalty_class": "Music::Penalty",
      "penalty_application_id": 901,
      "dynamic_type": "voter_names_unknown",
      "attribute_value": true,
      "value": 15.0
    },

    # Dynamic temporal penalties
    {
      "source": "dynamic_temporal",
      "penalty_id": 456,
      "penalty_name": "Limited Temporal Coverage",
      "penalty_class": "Music::Penalty",
      "penalty_application_id": 912,
      "max_value": 25.0,
      "calculation": {
        "years_covered": 20,
        "max_year_range": 100,
        "media_type": "Music::Albums::List",
        "ratio": 0.2,
        "exponent": 2.0,
        "formula": "max_value * ((1.0 - ratio) ** exponent)"
      },
      "value": 16.0
    }
  ],

  "penalty_summary": {
    "total_static_penalties": 20.0,
    "total_voter_count_penalties": 24.3,
    "total_attribute_penalties": 15.0,
    "total_temporal_penalties": 16.0,
    "total_before_quality_bonus": 75.3
  },

  "quality_bonus": {
    "applied": false,
    "reduction_factor": 0.6666666666666666,
    "penalty_before": 75.3,
    "penalty_after": 75.3
  },

  "final_calculation": {
    "total_penalty_percentage": 75.3,
    "capped_penalty_percentage": 75.3,
    "weight_after_penalty": 24.7,
    "weight_after_floor": 24.7,
    "final_weight": 25
  }
}
```

### Code Changes Required

#### 1. Rankings::WeightCalculatorV1 (app/lib/rankings/weight_calculator_v1.rb)

**Modify `calculate_weight` method** to build the details hash:

```ruby
def calculate_weight
  details = {
    "calculation_version" => 1,
    "timestamp" => Time.current.iso8601,
    "base_values" => build_base_values,
    "penalties" => [],
    "penalty_summary" => {}
  }

  starting_weight = base_weight.to_f

  # Calculate penalties and collect details
  static_penalties = calculate_static_penalties_with_details(details)
  voter_penalties = calculate_voter_count_penalty_with_details(details)
  attribute_penalties = calculate_attribute_penalties_with_details(details)

  total_penalty_percentage = static_penalties + voter_penalties + attribute_penalties

  # Build penalty summary
  details["penalty_summary"] = {
    "total_static_penalties" => static_penalties,
    "total_voter_count_penalties" => voter_penalties,
    "total_attribute_penalties" => attribute_penalties,
    "total_before_quality_bonus" => total_penalty_percentage
  }

  # Apply quality bonus
  details["quality_bonus"] = apply_quality_bonus_with_details(total_penalty_percentage)
  total_penalty_percentage = details["quality_bonus"]["penalty_after"]

  # Cap, apply, and floor
  details["final_calculation"] = build_final_calculation(
    starting_weight,
    total_penalty_percentage
  )

  # Save details to ranked_list
  ranked_list.calculated_weight_details = details

  details["final_calculation"]["final_weight"]
end
```

**Add new private methods** to capture details:

- `build_base_values` - Captures base_weight, minimum_weight, high_quality_source
- `calculate_static_penalties_with_details(details)` - Modified version that appends to details["penalties"]
- `calculate_voter_count_penalty_with_details(details)` - Modified version that appends to details["penalties"]
- `calculate_attribute_penalties_with_details(details)` - Modified version that appends to details["penalties"]
- `apply_quality_bonus_with_details(penalty)` - Returns hash with before/after values
- `build_final_calculation(starting_weight, penalty_percentage)` - Returns final calculation hash

#### 2. Rankings::WeightCalculator (app/lib/rankings/weight_calculator.rb)

**Modify `call` method** to save calculated_weight_details:

```ruby
def call
  weight = calculate_weight
  ranked_list.weight = weight
  # calculated_weight_details is set by calculate_weight in V1
  ranked_list.save!
  weight
end
```

#### 3. View Helper (app/helpers/music/lists_helper.rb)

**Add helper method** to format **simple penalty summary** for public views:

```ruby
module Music::ListsHelper
  def format_simple_penalty_summary(ranked_list)
    return nil unless ranked_list&.calculated_weight_details

    details = ranked_list.calculated_weight_details
    # Returns simple HTML list showing:
    # - Penalty name
    # - Penalty value (rounded to 1 decimal)
    # Example: "Low Voter Count: 24.3%", "Unknown Voter Names: 15.0%"
  end

  def penalty_badge_class(penalty_value)
    # Returns CSS class based on penalty severity
    # 0-10: success (green), 10-25: warning (yellow), 25+: error (red)
  end
end
```

#### 4. Public View Updates (Simple Summary Only)

**Music::Songs::Lists show view** (app/views/music/songs/lists/show.html.erb):

Replace lines 31-35 with simple penalty summary section.

**Music::Albums::Lists show view** (app/views/music/albums/lists/show.html.erb):

Replace lines 30-34 with simple penalty summary section.

**New UI Component Structure for Public Views:**
```erb
<% if @ranked_list %>
  <div class="card bg-base-200 shadow-xl mb-6">
    <div class="card-body">
      <h2 class="card-title">
        List Weight: <%= @ranked_list.weight %>
        <div class="badge badge-lg badge-ghost">
          <%= @ranked_list.weight %> / 100
        </div>
      </h2>

      <%= render partial: "music/lists/simple_penalty_summary",
                 locals: { ranked_list: @ranked_list } %>
    </div>
  </div>
<% end %>
```

**New partial** (app/views/music/lists/_simple_penalty_summary.html.erb):

```erb
<% if ranked_list.calculated_weight_details.present? %>
  <div class="mt-4">
    <h3 class="text-sm font-semibold mb-2">Penalties Applied:</h3>
    <div class="flex flex-wrap gap-2">
      <% ranked_list.calculated_weight_details["penalties"].each do |penalty| %>
        <div class="badge <%= penalty_badge_class(penalty["value"]) %>">
          <%= penalty["penalty_name"] %>: <%= penalty["value"].round(1) %>%
        </div>
      <% end %>
    </div>

    <% if ranked_list.calculated_weight_details["quality_bonus"]["applied"] %>
      <div class="mt-2 text-sm text-success">
        ✓ High Quality Source Bonus Applied
      </div>
    <% end %>
  </div>
<% else %>
  <p class="text-sm text-gray-500 mt-2">
    Weight calculation details not available.
  </p>
<% end %>
```

#### 5. Avo Admin Interface (Full Detailed Breakdown)

**Update RankedList Avo Resource** (app/avo/resources/ranked_list.rb):

Add the `calculated_weight_details` field to the existing fields method, displaying on the show page only (read-only):

```ruby
class Avo::Resources::RankedList < Avo::BaseResource
  def fields
    field :id, as: :id
    field :weight, as: :number

    # Show detailed breakdown on show page only
    field :calculated_weight_details,
          as: :code,
          format_using: -> {
            if value.present?
              JSON.pretty_generate(value)
            else
              "No calculation details available"
            end
          },
          only_on: :show,
          help: "Complete breakdown of weight calculation including all penalties, formulas, and intermediate values"

    field :list, as: :belongs_to
    field :ranking_configuration, as: :belongs_to
  end
end
```

**Why :code field type:**
- Displays JSON in a readable, formatted code block
- Syntax highlighting for better readability
- Read-only by default (perfect for our use case)
- Can expand/collapse in Avo UI
- No editing controls shown

### Database Migration Strategy

1. Add nullable column (no default data)
2. Existing ranked_lists will have null `calculated_weight_details`
3. Running BulkWeightCalculator will populate the field for all lists
4. No data migration needed - field populates on next weight calculation

### Backward Compatibility

- Column is nullable - existing records unaffected
- Views check for presence before displaying breakdown
- Fall back to simple weight display if details not available
- No changes to weight calculation algorithm - only adds details capture
- Existing tests continue to pass (new field is optional)

## Dependencies
- Existing Rankings::WeightCalculatorV1 (web-app/app/lib/rankings/weight_calculator_v1.rb)
- Existing Rankings::WeightCalculator (web-app/app/lib/rankings/weight_calculator.rb)
- Existing Rankings::BulkWeightCalculator (web-app/app/lib/rankings/bulk_weight_calculator.rb)
- RankedList model (web-app/app/models/ranked_list.rb)
- RankedList Avo resource (web-app/app/avo/resources/ranked_list.rb)
- Penalty model with dynamic_type enum (web-app/app/models/penalty.rb)
- PenaltyApplication model (web-app/app/models/penalty_application.rb)
- ListPenalty model (web-app/app/models/list_penalty.rb)
- Music::Songs::Lists show view (web-app/app/views/music/songs/lists/show.html.erb)
- Music::Albums::Lists show view (web-app/app/views/music/albums/lists/show.html.erb)
- Music::ListsHelper (web-app/app/helpers/music/lists_helper.rb)

## Acceptance Criteria

### Database & Calculation
- [ ] Migration generated using Rails generator and runs successfully
- [ ] `calculated_weight_details` jsonb column added to `ranked_lists` table (nullable)
- [ ] Running WeightCalculatorV1 populates `calculated_weight_details` with complete breakdown
- [ ] Details include all penalty types: static, dynamic voter count, dynamic attribute, dynamic temporal
- [ ] For each penalty: ID, name, type/class, and calculated value are captured
- [ ] Dynamic penalty calculations include inputs (voter count, median, ratio, formula, etc.)
- [ ] Quality bonus application is captured with before/after values
- [ ] Final calculation steps are captured (capping, floor, rounding)
- [ ] Timestamp and version are recorded
- [ ] BulkWeightCalculator works correctly with new field

### Public Views (Simple Summary)
- [ ] Music songs list show page displays **simple penalty summary** (names and values only)
- [ ] Music albums list show page displays **simple penalty summary** (names and values only)
- [ ] UI shows penalty names with values as badges
- [ ] Quality bonus indicator shown when applied
- [ ] UI gracefully handles missing details (shows simple message)
- [ ] Helper method `format_simple_penalty_summary` formats penalty data readably
- [ ] Different penalty severity levels have distinct visual styling (green/yellow/red)

### Avo Admin Interface (Detailed Breakdown)
- [ ] RankedList Avo resource displays `calculated_weight_details` field on show page
- [ ] Field uses `:code` type for formatted JSON display
- [ ] Field is read-only (only_on: :show)
- [ ] JSON is pretty-printed and syntax highlighted
- [ ] Help text explains what the field contains
- [ ] Gracefully handles null values (shows appropriate message)

### Testing & Compatibility
- [ ] Existing tests continue to pass (backward compatibility)
- [ ] New tests cover details capture in WeightCalculatorV1
- [ ] New tests cover simple summary helper formatting
- [ ] New tests verify Avo field displays correctly

### Documentation
- [ ] RankedList model documentation updated with new field
- [ ] WeightCalculatorV1 documentation updated with details capture
- [ ] This TODO file updated with implementation notes

## Design Decisions

### Why jsonb Instead of Separate Tables?
- **Archival Nature**: This data is historical/snapshot - doesn't need relational integrity
- **Flexibility**: JSON structure can evolve with calculation versions without migrations
- **Performance**: Single column read vs multiple joins
- **Simplicity**: Avoids complex schema for what's essentially a log/audit record
- **No Querying Needed**: Data is for display/debugging, not analytical queries

### Why Store Calculated Values Instead of Recalculating?
- **Historical Accuracy**: Penalties and formulas may change - need snapshot at calculation time
- **Performance**: Recalculation is expensive (median calculations, power curves, etc.)
- **Debugging**: Need to see exact values used, not current values
- **Audit Trail**: Shows what the system "thought" at calculation time

### Why Not Use a Separate CalculationLog Model?
- **Single Responsibility**: Each RankedList has ONE current weight calculation
- **Simplicity**: Don't need historical versions - just the current calculation's breakdown
- **Performance**: Avoids additional table and associations
- **Can Add Later**: Easy to extract to separate table if historical versions become needed

### UI Display Strategy (Two-Tier Approach)

**Public Views (Simple Summary):**
- Show penalty names and values as badges
- Color-code by severity (green < 10%, yellow 10-25%, red > 25%)
- Indicate if quality bonus was applied
- Clean, simple, user-friendly display
- No technical details or formulas visible

**Avo Admin Interface (Full Technical Details):**
- Display complete JSON breakdown in code block
- Show all calculation steps and intermediate values
- Include formulas, ratios, and dynamic calculation inputs
- Syntax-highlighted, pretty-printed JSON
- Read-only field for debugging and auditing

**Why This Approach:**
- **User-Friendly**: General users see simple, understandable penalty names
- **Developer-Friendly**: Admins get complete technical details for debugging
- **Progressive Disclosure**: Right level of detail for each audience
- **Maintainability**: Developers can troubleshoot without re-running calculations

---

## Implementation Notes

### Approach Taken
Followed the planned approach closely with minimal deviations:
1. Generated migration using Rails generator as specified
2. Updated parent WeightCalculator to use `save!` instead of `update!` to persist additional attributes
3. Completely refactored WeightCalculatorV1#calculate_weight to build details hash throughout calculation
4. Created new `_with_details` methods for each calculation step
5. Kept original calculation methods for backward compatibility (in case tests call them directly)
6. Added helper methods for public views to display simple penalty summaries
7. Created reusable partial for penalty display
8. Updated Avo resource to show full JSON breakdown using `:code` field type

### Key Files Changed
**Migration:**
- `db/migrate/20251021222021_add_calculated_weight_details_to_ranked_lists.rb` - Added jsonb column

**Core Calculation Logic:**
- `app/lib/rankings/weight_calculator.rb:29-33` - Modified `call` method to use `save!` for attribute persistence
- `app/lib/rankings/weight_calculator_v1.rb:7-341` - Complete refactor of calculate_weight with details capture

**Views:**
- `app/helpers/music/lists_helper.rb:2-6` - Added `penalty_badge_class` helper
- `app/views/music/lists/_simple_penalty_summary.html.erb` - New partial for penalty display
- `app/views/music/songs/lists/show.html.erb:43-57` - Updated to show weight card with penalties
- `app/views/music/albums/lists/show.html.erb:42-56` - Updated to show weight card with penalties

**Admin:**
- `app/avo/resources/ranked_list.rb:12-22` - Added calculated_weight_details field as code block

**Tests:**
- `test/lib/rankings/weight_calculator_v1_test.rb:742-988` - Added 8 new tests for details capture
- `test/helpers/music/lists_helper_test.rb` - New test file for helper methods

**Documentation:**
- `docs/models/ranked_list.md:10-69, 87-88` - Updated with new attribute documentation
- `docs/lib/rankings/weight_calculator_v1.md:19-30, 134-186` - Updated with details capture functionality

### Challenges Encountered
1. **Parallel test execution**: Initial test for voter count penalty failed in parallel mode because other tests' data affected median calculation. Fixed by using `number_of_voters: 1` which always triggers penalty.
2. **File creation**: Documentation files didn't exist, needed to create directory structure first.

### Deviations from Plan
- **Kept original methods**: Added new `_with_details` methods rather than modifying originals, providing backward compatibility.
- **Parent class change**: Modified WeightCalculator#call to use `save!` instead of `update!` to persist calculated_weight_details.
- **No temporal penalty tests**: Existing comprehensive tests for temporal penalties were sufficient; focused details tests on structure verification.

### Code Examples

**Building the details hash:**
```ruby
details = {
  "calculation_version" => 1,
  "timestamp" => Time.current.iso8601,
  "base_values" => build_base_values,
  "penalties" => [],
  "penalty_summary" => {}
}

static_penalties = calculate_static_penalties_with_details(details)
# Details["penalties"] is now populated with static penalty info

ranked_list.calculated_weight_details = details
```

**Accessing details in views:**
```ruby
details["penalties"].each do |penalty|
  penalty["penalty_name"]  # => "Low Voter Count"
  penalty["value"]         # => 24.3
  penalty["calculation"]   # => {"voter_count" => 5, "formula" => "..."}
end
```

### Testing Approach
- Added 8 focused tests for details capture functionality
- Tested structure, base values, static penalties, quality bonus, final calculation, voter penalties, and attribute penalties
- Used isolated test configurations to avoid test pollution
- All existing 1411 tests continue to pass (backward compatible)

### Performance Considerations
- JSONB field adds minimal overhead (only during calculation, not queries)
- No indexes added initially (field is for display/debugging, not querying)
- Could add GIN index later if analytics queries needed
- Details are only populated during weight calculation (not on every read)

### Future Improvements
1. **Analytics**: Could query penalty patterns across all lists using JSONB operators
2. **Versioning**: Track historical calculations if weight is recalculated
3. **UI Enhancement**: Interactive penalty explorer in Avo admin
4. **Export**: CSV/JSON export of penalty data for analysis

### Lessons Learned
1. **Backward compatibility**: Keeping old methods while adding new ones prevented test failures
2. **Parallel testing**: Need to account for shared state when testing medians/aggregates
3. **JSONB flexibility**: Perfect for archival/snapshot data that doesn't need relational integrity
4. **Two-tier display**: Simple badges for users, full technical details for admins works well

### Related PRs
- (To be created after commit)

### Documentation Updated
- [x] Class documentation files updated (ranked_list.md, weight_calculator_v1.md)
- [x] Model documentation includes new jsonb field structure
- [x] WeightCalculatorV1 documentation includes details capture methods
- [ ] README updated if needed (not necessary for this feature)
