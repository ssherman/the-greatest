# 070 - Voter Count Estimated Dynamic Penalty

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-11-04
- **Started**: 2025-11-05
- **Completed**: 2025-11-05
- **Developer**: Claude

## Overview
Implement a new dynamic penalty field `voter_count_estimated` to handle lists where we didn't know the exact voter count but estimated it based on various sources and heuristics. This penalty acknowledges that estimated voter counts are less reliable than known exact counts.

## Context
- Currently we have `voter_count_unknown` and `voter_names_unknown` penalties for data completeness issues
- In some cases, we can estimate voter counts from contextual information (e.g., award descriptions, historical records, publication circulation numbers) but these estimates are not as reliable as exact counts
- This field allows us to distinguish between "we have no idea" (`voter_count_unknown`) and "we made an educated guess" (`voter_count_estimated`)
- Lists with estimated voter counts should receive a penalty, but potentially less severe than completely unknown voter counts

## Requirements
- [ ] Generate migration using Rails generator to add `voter_count_estimated` boolean field to `lists` table
- [ ] Run migration (schema annotations will update automatically)
- [ ] Update `Rankings::WeightCalculatorV1` to apply penalty for this attribute
- [ ] Update Avo `List` resource to display and edit the new field
- [ ] Add `voter_count_estimated` to penalty seed data
- [ ] Update List model documentation
- [ ] Update WeightCalculatorV1 documentation
- [ ] Write comprehensive tests

## Technical Approach

### 1. Database Migration
Use Rails generator to create the migration:

```bash
cd web-app
bin/rails generate migration AddVoterCountEstimatedToLists voter_count_estimated:boolean
```

This will generate:

```ruby
class AddVoterCountEstimatedToLists < ActiveRecord::Migration[8.0]
  def change
    add_column :lists, :voter_count_estimated, :boolean
  end
end
```

Then run the migration:

```bash
bin/rails db:migrate
```

**Key aspects:**
- Boolean type with no constraints
- Nullable (no default value)
- Schema annotations in `List` model will update automatically after migration runs

### 2. Model Changes
No code changes needed in the `List` model. Schema annotations will be updated automatically when running the migration. The annotation will include:

```ruby
# == Schema Information
#
# Table name: lists
#
#  voter_count_unknown     :boolean
#  voter_count_estimated   :boolean  # Will appear after migration
#  voter_names_unknown     :boolean
```

No validations or scopes needed for this simple boolean attribute.

### 3. WeightCalculatorV1 Updates
Add penalty calculation to `calculate_unknown_data_penalties_with_details` method following the exact pattern of `voter_count_unknown`:

**Location:** `app/lib/rankings/weight_calculator_v1.rb:157-187`

```ruby
def calculate_unknown_data_penalties_with_details(details)
  penalty = 0

  # Existing voter_names_unknown logic...

  # Existing voter_count_unknown logic...

  # NEW: Add voter_count_estimated penalty
  if list.voter_count_estimated?
    penalty_value, penalty_info = find_penalty_details_by_dynamic_type(:voter_count_estimated)
    if penalty_value > 0
      penalty += penalty_value
      details["penalties"] << penalty_info.merge(
        "source" => "dynamic_attribute",
        "dynamic_type" => "voter_count_estimated",
        "attribute_value" => true,
        "value" => penalty_value
      )
    end
  end

  penalty
end
```

Also update the simpler non-detailed version at `app/lib/rankings/weight_calculator_v1.rb:428-442`:

```ruby
def calculate_unknown_data_penalties
  penalty = 0

  # Penalty for unknown voter names
  if list.voter_names_unknown?
    penalty += find_penalty_value_by_dynamic_type(:voter_names_unknown)
  end

  # Penalty for unknown voter count
  if list.voter_count_unknown?
    penalty += find_penalty_value_by_dynamic_type(:voter_count_unknown)
  end

  # NEW: Penalty for estimated voter count
  if list.voter_count_estimated?
    penalty += find_penalty_value_by_dynamic_type(:voter_count_estimated)
  end

  penalty
end
```

### 4. Penalty Enum Update
Add new dynamic_type to the Penalty model enum:

**Location:** `app/models/penalty.rb:32-40`

```ruby
enum :dynamic_type, {
  number_of_voters: 0,
  percentage_western: 1,
  voter_names_unknown: 2,
  voter_count_unknown: 3,
  category_specific: 4,
  location_specific: 5,
  num_years_covered: 6,
  voter_count_estimated: 7  # NEW
}, allow_nil: true
```

### 5. Seed Data Update
Add new penalty to seed definitions:

**Location:** `db/seeds.rb:15-36`

```ruby
penalty_definitions = [
  # ... existing penalties ...

  {name: "Voters: Unknown Names", dynamic_type: :voter_names_unknown},
  {name: "Voters: Voter Count", dynamic_type: :number_of_voters},
  {name: "Voters: Unknown Count", dynamic_type: :voter_count_unknown},
  {name: "Voters: Estimated Count", dynamic_type: :voter_count_estimated},  # NEW

  # ... remaining penalties ...
]
```

### 6. Avo Resource Update
Add field to List resource following existing boolean field pattern:

**Location:** `app/avo/resources/list.rb:25-26`

```ruby
field :number_of_voters, as: :number
field :voter_count_unknown, as: :boolean
field :voter_count_estimated, as: :boolean       # NEW
field :voter_names_unknown, as: :boolean
```

**Placement:** Insert between `voter_count_unknown` and `voter_names_unknown` for logical grouping.

### 7. Testing Approach
Follow existing test patterns from `voter_count_unknown`:

**Location:** `test/lib/rankings/weight_calculator_v1_test.rb`

Create test lists with `voter_count_estimated: true`:
```ruby
test "applies penalty for estimated voter count" do
  estimated_voters_list = Books::List.create!(
    name: "Estimated Voters List",
    status: :approved,
    voter_count_estimated: true
  )

  # Create penalty with dynamic_type
  estimated_penalty = Global::Penalty.create!(
    type: "Global::Penalty",
    name: "Estimated Voter Count",
    dynamic_type: :voter_count_estimated
  )

  # Create penalty application
  PenaltyApplication.create!(
    penalty: estimated_penalty,
    ranking_configuration: @books_config,
    value: 10  # Could be less severe than unknown (15)
  )

  # Create comparison lists
  clean_list = Books::List.create!(
    name: "Clean List",
    status: :approved,
    voter_count_estimated: false
  )

  # Calculate weights
  estimated_ranked = RankedList.create!(list: estimated_voters_list, ranking_configuration: @books_config)
  clean_ranked = RankedList.create!(list: clean_list, ranking_configuration: @books_config)

  estimated_weight = WeightCalculatorV1.new(estimated_ranked).call
  clean_weight = WeightCalculatorV1.new(clean_ranked).call

  # Assert penalty applied
  assert_operator clean_weight, :>, estimated_weight
end
```

Test calculation details tracking:
```ruby
test "captures voter_count_estimated penalty details" do
  test_config = Music::Albums::RankingConfiguration.create!(
    name: "Estimated Voter Details Test #{SecureRandom.hex(4)}",
    global: true,
    min_list_weight: 1
  )

  test_list = Music::Albums::List.create!(
    name: "Estimated Voter Details List",
    status: :approved,
    voter_count_estimated: true
  )

  estimated_penalty = Global::Penalty.create!(
    type: "Global::Penalty",
    name: "Estimated Voter Count Penalty",
    dynamic_type: :voter_count_estimated
  )

  PenaltyApplication.create!(
    penalty: estimated_penalty,
    ranking_configuration: test_config,
    value: 10
  )

  test_ranked_list = RankedList.create!(list: test_list, ranking_configuration: test_config)
  calculator = WeightCalculatorV1.new(test_ranked_list)
  calculator.call

  details = test_ranked_list.reload.calculated_weight_details
  attribute_penalties = details["penalties"].select { |p| p["source"] == "dynamic_attribute" && p["dynamic_type"] == "voter_count_estimated" }

  assert_equal 1, attribute_penalties.size
  penalty_detail = attribute_penalties.first
  assert_equal "dynamic_attribute", penalty_detail["source"]
  assert_equal "voter_count_estimated", penalty_detail["dynamic_type"]
  assert_equal true, penalty_detail["attribute_value"]
  assert_equal 10, penalty_detail["value"]
end
```

## Dependencies
- Existing `Rankings::WeightCalculatorV1` implementation (completed in todo 036)
- Penalty model with dynamic_type enum
- PenaltyApplication model
- List model
- Avo admin interface

## Acceptance Criteria
- [ ] Migration generated using Rails generator and successfully run
- [ ] `voter_count_estimated` boolean column exists in lists table
- [ ] `List` model schema annotation automatically includes new field
- [ ] `Rankings::WeightCalculatorV1` applies penalty when `voter_count_estimated` is true
- [ ] Penalty details are captured in `calculated_weight_details` JSON
- [ ] Avo List resource displays and allows editing of new field
- [ ] Seed data includes new penalty definition
- [ ] All existing tests continue to pass
- [ ] New tests verify penalty application and details tracking
- [ ] Lists with `voter_count_estimated: true` receive appropriate weight penalties
- [ ] Documentation updated for List model and WeightCalculatorV1

## Design Decisions

### Penalty Severity
The recommended penalty value for `voter_count_estimated` should be less severe than `voter_count_unknown` since an estimate is better than no data. Suggested values:
- `voter_count_unknown`: 15% penalty (existing)
- `voter_count_estimated`: 10% penalty (new - recommended)
- `voter_names_unknown`: 15% penalty (existing)

This allows admins to configure penalty severity per ranking configuration via PenaltyApplication.

### Field Semantics
The three voter-related boolean fields have distinct meanings:
- `voter_count_unknown`: We have no information about voter count
- `voter_count_estimated`: We estimated voter count from contextual information
- `voter_names_unknown`: We don't know who the individual voters were

Lists can have multiple flags set (e.g., `voter_count_estimated: true` AND `voter_names_unknown: true`).

### Integration with number_of_voters Field
- If `voter_count_estimated: true`, the `number_of_voters` field contains the estimated value
- If `voter_count_unknown: true`, the `number_of_voters` field should be NULL
- These fields are complementary and penalties stack (if both unknown and estimated penalties exist)

---

## Implementation Notes

### Approach Taken
Followed the exact pattern established by `voter_count_unknown` penalty implementation. Used Rails generators for migration, followed existing code patterns for penalty logic, and wrote comprehensive tests mirroring existing test structure.

### Key Files Changed
1. **Migration**: `db/migrate/20251105010109_add_voter_count_estimated_to_lists.rb`
   - Added `voter_count_estimated:boolean` column to `lists` table
   - Auto-annotated all List models and fixtures

2. **Model**: `app/models/penalty.rb:40`
   - Added `voter_count_estimated: 7` to dynamic_type enum

3. **Weight Calculator**: `app/lib/rankings/weight_calculator_v1.rb`
   - Lines 186-197: Added penalty logic in `calculate_unknown_data_penalties_with_details`
   - Lines 454-457: Added penalty logic in `calculate_unknown_data_penalties`

4. **Avo Resource**: `app/avo/resources/list.rb:26`
   - Added field display between `voter_count_unknown` and `voter_names_unknown`

5. **Seed Data**: `db/seeds.rb:33`
   - Added `{name: "Voters: Estimated Count", dynamic_type: :voter_count_estimated}`

6. **Tests**: `test/lib/rankings/weight_calculator_v1_test.rb:989-1061`
   - Added two comprehensive tests for penalty application and details tracking

### Challenges Encountered
None. Implementation was straightforward following existing patterns.

### Deviations from Plan
No deviations. Implementation followed spec exactly.

### Code Examples
```ruby
# Example usage in list creation
list = Books::List.create!(
  name: "Best Books of the Decade",
  status: :approved,
  number_of_voters: 50,           # Estimated value
  voter_count_estimated: true     # Flag indicating estimate
)

# Penalty will be applied automatically by WeightCalculatorV1
ranked_list = RankedList.create!(list: list, ranking_configuration: config)
calculator = Rankings::WeightCalculatorV1.new(ranked_list)
weight = calculator.call  # Applies voter_count_estimated penalty

# Check penalty details
ranked_list.calculated_weight_details["penalties"].select do |p|
  p["dynamic_type"] == "voter_count_estimated"
end
```

### Testing Approach
- Created two tests following existing patterns from `voter_count_unknown` tests
- Test 1: Verifies penalty application (weight comparison between estimated and clean lists)
- Test 2: Verifies penalty details capture in `calculated_weight_details` JSON
- All 1,591 tests pass with 0 failures

### Performance Considerations
No performance impact. The penalty check is a simple boolean attribute check in memory, identical to existing penalty checks.

### Future Improvements
- Consider adding validation to prevent both `voter_count_unknown` and `voter_count_estimated` being true simultaneously
- Could add admin UI warnings when both flags are set
- May want to track the source/method of estimation in a separate field for audit purposes

### Lessons Learned
- Following existing patterns makes implementation fast and reliable
- Rails generators + auto-annotation = minimal manual work
- Comprehensive test coverage caught no issues (good pattern compliance)

### Related PRs
None yet (implementation complete, ready for commit)

### Documentation Updated
- [x] `docs/models/list.md` - Added voter_count_estimated field and voter field semantics section
- [x] `docs/models/penalty.md` - Added voter_count_estimated to dynamic_type enum with hierarchy explanation
- [x] `docs/lib/rankings/weight_calculator_v1.md` - Documented new penalty type and voter count hierarchy
- [x] Class documentation updated (schema annotations auto-updated by Rails)
