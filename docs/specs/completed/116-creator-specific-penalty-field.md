# [116] - Add creator_specific Boolean Field and Dynamic Penalty

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-15
- **Started**: 2026-01-16
- **Completed**: 2026-01-16
- **Developer**: Claude Code

## Overview
Add a new `creator_specific` boolean field to the List model to indicate when a list focuses on a single creator (author for books, artist for music, director/actor for movies, developer for games). This field will trigger a dynamic penalty in the weight calculation algorithm, similar to how `category_specific` and `location_specific` work, but in a new separate penalty category.

**Non-goals**:
- Not creating default penalty values (admin will configure)
- Not updating deprecated Avo admin interfaces

## Context & Links
- Related tasks/phases: Ranking algorithm improvements
- Source files (authoritative):
  - `app/models/list.rb`
  - `app/models/penalty.rb`
  - `app/lib/rankings/weight_calculator_v1.rb`
  - `app/views/admin/music/albums/lists/_form.html.erb`
  - `app/views/admin/music/songs/lists/_form.html.erb`
- External docs: None required

## Interfaces & Contracts

### Domain Model (diffs only)

**Migration** (REQUIRED): Create a new Rails migration to add the field.

File: `db/migrate/YYYYMMDDHHMMSS_add_creator_specific_to_lists.rb`
```ruby
# reference only
class AddCreatorSpecificToLists < ActiveRecord::Migration[8.0]
  def change
    add_column :lists, :creator_specific, :boolean
  end
end
```
- Add boolean column `creator_specific` to `lists` table (nullable, default nil)
- Run `bin/rails db:migrate` after creating migration
- Run `bin/annotaterb models` to update schema annotations in model files

**Penalty enum addition** (`app/models/penalty.rb`):
- Add `creator_specific: 8` to `dynamic_type` enum (next available integer value)

### Endpoints
No new endpoints. Existing custom admin endpoints handle form fields automatically via strong parameters.

### Schemas (JSON)

**calculated_weight_details penalty entry (when creator_specific penalty applied)**:
```json
{
  "source": "dynamic_attribute",
  "dynamic_type": "creator_specific",
  "attribute_value": true,
  "value": 10.0,
  "penalty_id": 123,
  "penalty_name": "Creator Specific Penalty",
  "penalty_class": "Global::Penalty",
  "penalty_application_id": 456
}
```

### Behaviors (pre/postconditions)

**Preconditions**:
- List record exists
- RankingConfiguration has a Penalty with `dynamic_type: :creator_specific` and associated PenaltyApplication with a value

**Postconditions**:
- When `list.creator_specific? == true`, the calculator applies the configured penalty value
- When `list.creator_specific? == false` or `nil`, no penalty is applied
- Penalty details are recorded in `calculated_weight_details`

**Edge cases & failure modes**:
- No penalty configured with `dynamic_type: :creator_specific`: No penalty applied, no error
- Multiple penalties with same dynamic_type: Values are summed (existing behavior)
- Field is nil: Treated as false (no penalty applied)

### Non-Functionals
- No N+1 queries: Follows existing pattern using joins
- No performance impact: Single boolean check in calculation loop

## Acceptance Criteria

### Database & Model
- [x] Migration created and adds `creator_specific` boolean column to `lists` table
- [x] Migration runs successfully (`bin/rails db:migrate`)
- [x] Schema annotations updated (`bin/annotaterb models`)
- [x] `Penalty.dynamic_types` includes `:creator_specific` with value `8`

### Weight Calculator
- [x] `WeightCalculatorV1#calculate_creator_penalties_with_details` method exists
- [x] Method is called from `calculate_attribute_penalties_with_details`
- [x] When `list.creator_specific? == true` and penalty is configured, penalty is applied and recorded in details

### Admin UI (Custom Admin - NOT Avo)
- [x] Album list form (`app/views/admin/music/albums/lists/_form.html.erb`) includes `creator_specific` checkbox in Flags section
- [x] Song list form (`app/views/admin/music/songs/lists/_form.html.erb`) includes `creator_specific` checkbox in Flags section
- [x] Strong parameters updated in relevant controllers to permit `creator_specific`

### Documentation & Tests
- [x] Documentation updated: `docs/lib/rankings/weight_calculator_v1.md`
- [x] Tests pass for new penalty calculation logic

### Golden Examples

**Example 1: Creator-specific list with penalty configured**
```text
Input:
  - list.creator_specific = true
  - Penalty exists with dynamic_type: :creator_specific
  - PenaltyApplication links penalty to ranking_config with value: 15

Output:
  - 15% added to total_attribute_penalties
  - calculated_weight_details includes penalty entry with:
    - source: "dynamic_attribute"
    - dynamic_type: "creator_specific"
    - value: 15
```

**Example 2: Creator-specific list with no penalty configured**
```text
Input:
  - list.creator_specific = true
  - No Penalty with dynamic_type: :creator_specific exists

Output:
  - 0% added (no penalty applied)
  - No entry in calculated_weight_details for creator_specific
```

### Optional Reference Snippets (<=40 lines each, non-authoritative)

**Weight Calculator Method**:
```ruby
# reference only - pattern from existing bias penalties
def calculate_creator_penalties_with_details(details)
  penalty = 0

  if list.creator_specific?
    penalty_value, penalty_info = find_penalty_details_by_dynamic_type(:creator_specific)
    if penalty_value > 0
      penalty += penalty_value
      details["penalties"] << penalty_info.merge(
        "source" => "dynamic_attribute",
        "dynamic_type" => "creator_specific",
        "attribute_value" => true,
        "value" => penalty_value
      )
    end
  end

  penalty
end
```

**Form Checkbox (add to Flags section in both album/song list forms)**:
```erb
<!-- reference only - add after voter_names_unknown checkbox -->
<div class="form-control">
  <label class="label cursor-pointer justify-start gap-4">
    <%= f.check_box :creator_specific, class: "checkbox" %>
    <span class="label-text">Creator Specific</span>
  </label>
</div>
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> collect comparable patterns (existing dynamic_type additions)
2) codebase-analyzer -> verify data flow & integration points
3) web-search-researcher -> not needed (internal feature)
4) technical-writer -> update docs and cross-refs

### Test Seed / Fixtures
- `test/lib/rankings/weight_calculator_v1_test.rb`: Add tests following existing pattern for `category_specific` tests
- Factory/fixture for list with `creator_specific: true`

---

## Implementation Notes (living)
- Approach taken: Followed existing patterns from `category_specific` and `location_specific` exactly
- Important decisions: Created separate `calculate_creator_penalties_with_details` method rather than adding to `calculate_bias_penalties_with_details` for cleaner separation of concerns

### Key Files Touched (paths only)

**Database**:
- `db/migrate/20260116053028_add_creator_specific_to_lists.rb` (new migration)
- `db/seeds.rb` (added creator_specific penalty to seeds)

**Models**:
- `app/models/list.rb` (schema annotation auto-update via annotaterb)
- `app/models/penalty.rb` (add `creator_specific: 8` to enum)

**Weight Calculator**:
- `app/lib/rankings/weight_calculator_v1.rb` (add `calculate_creator_penalties_with_details` method)

**Admin UI (Custom Admin)**:
- `app/views/admin/music/albums/lists/_form.html.erb` (add checkbox in Flags section)
- `app/views/admin/music/songs/lists/_form.html.erb` (add checkbox in Flags section)
- `app/controllers/admin/music/lists_controller.rb` (add `:creator_specific` to `list_params`)

**Documentation**:
- `docs/lib/rankings/weight_calculator_v1.md` (update documentation)

**Tests**:
- `test/lib/rankings/weight_calculator_v1_test.rb` (add tests)

### Challenges & Resolutions
- None encountered; implementation followed existing patterns exactly

### Deviations From Plan
- Added `db/seeds.rb` update to include the creator_specific penalty (not in original spec but necessary for usability)

## Acceptance Results
- **Date**: 2026-01-16
- **Verifier**: Claude Code (automated)
- **Test Results**: All 26 weight calculator tests pass, all 39 penalty/list model tests pass
- **Artifacts**: Migration `20260116053028_add_creator_specific_to_lists.rb` applied successfully

## Future Improvements
- Consider adding help text to the checkbox explaining what "creator specific" means (e.g., "Artist Specific" for music)
- Add the field to other media type admin forms (books, movies, games) when those custom admin interfaces are built

## Related PRs
- #...

## Documentation Updated
- [x] `documentation.md` (no changes needed - pattern already documented)
- [x] Class docs (`docs/lib/rankings/weight_calculator_v1.md`)
