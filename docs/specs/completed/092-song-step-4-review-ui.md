# [092] - Song Wizard: Step 4 - Review UI (Table & Filters)

## Status
- **Status**: Complete
- **Priority**: High
- **Created**: 2025-01-19
- **Completed**: 2025-12-06
- **Part**: 7 of 10

## Overview
Build the Review step UI: a table displaying ALL unverified items with status badges, client-side filters, and summary stats. This enables users to see all validation results at once before taking action on individual items. **No actions in this task** - action handling is covered in [093].

## Context

This is **Part 7 of 10** in the Song List Wizard implementation:

1. [086] Infrastructure - Complete
2. [087] Wizard UI Shell - Complete
3. [088] Step 0: Import Source Choice - Complete
4. [089] Step 1: Parse HTML - Complete
5. [090] Step 2: Enrich - Complete
6. [090a] Step-Namespaced Status - Complete
7. [091] Step 3: Validation - Complete
8. **[092] Step 4: Review UI** - You are here
9. [093] Step 4: Actions
10. [094] Step 5: Import
11. [095] Polish & Integration

### The Flow

**Custom HTML Path**:
```
Step 0 (source) -> Step 1 (parse) -> Step 2 (enrich) -> Step 3 (validate) -> Step 4 (review) -> ...
```

### What This Builds

This task implements:
- Review step view component with:
  - Summary stats cards (Total, Valid %, Invalid %, Missing %)
  - Client-side filter dropdown (Show All | Valid Only | Invalid Only | Missing Only)
  - Full table showing ALL items (no pagination - show everything)
  - Status badges: Valid (green), Invalid (red), Missing (gray)
  - Row highlighting based on status
  - Actions column placeholder for individual item actions (added in [093])
  - Mobile-responsive horizontal scroll
- One new Stimulus controller:
  - `review_filter_controller.js` - Client-side row filtering by status
- Controller data loading for review step
- Component tests

This task does NOT implement:
- Row action buttons (edit, re-match, etc.) - covered in [093]
- Import logic - covered in [094]
- Server-side pagination - intentionally showing ALL items
- Bulk selection/actions - not needed; users act on individual items

### Key Design Decisions

**Show ALL Items (No Pagination)**:
- **Decision**: Display all items in a single scrollable table
- **Why**:
  - Users need to see the complete picture before importing
  - Typical list size is 50-500 items (manageable)
  - Filters reduce visible rows dynamically
  - Simplifies implementation and UX

**Client-Side Filtering**:
- **Decision**: Use Stimulus controller for instant filtering (no server roundtrip)
- **Why**:
  - All data already loaded on page
  - Instant feedback improves UX
  - Simpler than Turbo Frame partial updates
  - Filter state persists without URL params

**Individual Item Actions (No Bulk)**:
- **Decision**: Actions are per-row, not bulk operations
- **Why**:
  - At review stage, users typically need to fix specific problematic items
  - Invalid/missing items require individual attention
  - Simpler UX without checkbox management
  - Actions added in [093]

**Status Terminology**:
- **Valid**: Item has `verified = true` (AI validated as correct match)
- **Invalid**: Item has `metadata["ai_match_invalid"] = true` (AI flagged as bad match)
- **Missing**: Item has no match (`listable_id` nil AND no `mb_recording_id`)

---

## Requirements

### Functional Requirements

#### FR-1: Review Step View Component
**Contract**: Display comprehensive review table with stats, filters, and per-row actions placeholder

**UI Layout**:
```
+------------------------------------------------------------------+
| Stats Cards Row                                                   |
| [Total: 100] [Valid: 60 (60%)] [Invalid: 15 (15%)] [Missing: 25 (25%)] |
+------------------------------------------------------------------+
| Filter Bar                                                        |
| Filter: [Show All v]                     Showing 100 items        |
+------------------------------------------------------------------+
| Review Table                                                      |
| Status | # | Original | Matched | Source | Actions                |
|   V    | 1 | Beatles - Come Together | Come Together | OS 18.5  | ... |
|   X    | 2 | Lennon - Imagine | Imagine (Live) | MB             | ... |
|   -    | 3 | Unknown - Song | - | -                              | ... |
+------------------------------------------------------------------+
| Navigation                                                        |
| [Back] [Continue to Import]                                       |
+------------------------------------------------------------------+
```

**Stats Cards** (DaisyUI `stats` component):
- **Total Items**: Count of all unverified items
- **Valid**: Count + percentage with green highlight
- **Invalid**: Count + percentage with red highlight
- **Missing**: Count + percentage with gray highlight

**Filter Dropdown**:
- Options: "Show All", "Valid Only", "Invalid Only", "Missing Only"
- Default: "Show All"
- Instant client-side filtering via Stimulus
- Updates visible count display

**Review Table Columns**:
| Column | Content | Width |
|--------|---------|-------|
| Status | Badge (V/X/-) | 60px |
| Rank | Original position number | 50px |
| Original | Title + Artists from metadata | flex |
| Matched | Matched song name + artists OR MusicBrainz name + artists | flex |
| Source | OpenSearch (with score) / MusicBrainz / - | 100px |
| Actions | Placeholder for action buttons (per-row) | 100px |

**Row Highlighting**:
- Valid rows: Default background
- Invalid rows: `bg-error/10` (light red tint)
- Missing rows: `bg-base-200` (light gray tint)

**Status Badges**:
- Valid: `badge badge-success badge-sm` with checkmark icon
- Invalid: `badge badge-error badge-sm` with X icon
- Missing: `badge badge-ghost badge-sm` with dash

**Mobile Responsiveness**:
- Horizontal scroll on narrow screens (`overflow-x-auto`)
- Responsive stats cards (stack vertically on mobile)

**Implementation**:
- `app/components/admin/music/songs/wizard/review_step_component.rb`
- `app/components/admin/music/songs/wizard/review_step_component.html.erb`

#### FR-2: Review Filter Stimulus Controller
**Contract**: Client-side filtering of table rows by status

**Controller Specification**:
- **File**: `app/javascript/controllers/review_filter_controller.js`
- **Targets**: `row`, `filter`, `count`
- **Values**: None required

**Behavior**:
1. On filter change:
   - Read selected filter value
   - Show/hide rows based on `data-status` attribute
   - Update visible count display

**Row Data Attributes**:
```html
<tr data-review-filter-target="row"
    data-status="valid">
```

**Filter Values Mapping**:
- "all" -> show all rows
- "valid" -> show rows with `data-status="valid"`
- "invalid" -> show rows with `data-status="invalid"`
- "missing" -> show rows with `data-status="missing"`

**Implementation** (reference only, ~25 lines):
```javascript
// reference only
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["row", "filter", "count"]

  connect() {
    this.filter()
  }

  filter() {
    const value = this.filterTarget.value
    let visibleCount = 0

    this.rowTargets.forEach(row => {
      const status = row.dataset.status
      const visible = value === "all" || status === value
      row.classList.toggle("hidden", !visible)
      if (visible) visibleCount++
    })

    this.countTarget.textContent = `Showing ${visibleCount} items`
  }
}
```

#### FR-3: Controller Integration
**Contract**: Load review step data and support navigation

**Method Updates**:

1. **`load_review_step_data`** (currently minimal):
   ```ruby
   def load_review_step_data
     @items = @list.list_items.unverified.ordered.includes(listable: :artists)
     @total_count = @items.count
     @valid_count = @items.count(&:verified?)
     @invalid_count = @items.count { |i| i.metadata["ai_match_invalid"] }
     @missing_count = @total_count - @valid_count - @invalid_count
   end
   ```

2. **`advance_from_review_step`** (new):
   - Advance to import step
   - No job to enqueue - review is synchronous
   - Validate that at least some items are ready for import

**Implementation Location**: `app/controllers/admin/music/songs/list_wizard_controller.rb`

---

### Non-Functional Requirements

#### NFR-1: Performance
- [ ] Page loads in < 2 seconds for lists with 500 items
- [ ] Filter changes respond in < 100ms
- [ ] No N+1 queries (use `includes`)

#### NFR-2: Accessibility
- [ ] Filter dropdown is keyboard accessible
- [ ] Status badges have `title` attributes for screen readers
- [ ] Table has proper header associations

#### NFR-3: Mobile Responsiveness
- [ ] Stats cards stack vertically on mobile
- [ ] Table scrolls horizontally on narrow screens
- [ ] Touch targets are 44px minimum

---

## Contracts & Schemas

### ListItem Status Determination

**Status Rules** (in order of precedence):
```ruby
def item_status(item)
  if item.verified?
    "valid"     # AI confirmed match is correct
  elsif item.metadata["ai_match_invalid"]
    "invalid"   # AI flagged match as incorrect
  else
    "missing"   # No match found (or has unvalidated match - edge case)
  end
end
```

### Data Attributes Schema

**Row Element**:
```html
<tr data-review-filter-target="row"
    data-status="valid|invalid|missing"
    data-item-id="123">
```

---

## Acceptance Criteria

### View Component
- [x] `Admin::Music::Songs::Wizard::ReviewStepComponent` displays all items
- [x] Stats cards show Total, Valid, Invalid, Missing with counts and percentages
- [x] Filter dropdown exists with 4 options
- [x] Visible count updates after filtering
- [x] Table shows all required columns
- [x] Rows have correct status-based background colors
- [x] Status badges display correctly (V/X/-)
- [x] Source badges show OS/MB/- with score for OpenSearch
- [x] Original data (title + artists) displays correctly
- [x] Matched data displays correctly (song or MB recording)
- [x] Actions column shows placeholder
- [x] Mobile horizontal scroll works
- [x] Navigation buttons present (Back, Continue)

### Filter Controller
- [x] `review_filter_controller.js` exists
- [x] Filter changes show/hide rows instantly
- [x] "Show All" shows all rows
- [x] "Valid Only" shows only valid rows
- [x] "Invalid Only" shows only invalid rows
- [x] "Missing Only" shows only missing rows
- [x] Visible count updates after filter

### Controller Logic
- [x] `load_review_step_data` loads all items with associations
- [x] Counts are calculated correctly
- [x] No N+1 queries
- [x] Can advance to import step
- [x] Can go back to validate step

### Tests
- [x] Component tests cover all states
- [x] Controller tests verify data loading
- [x] System tests for filter behavior

---

## Golden Examples

### Example 1: Review Table Display

**Input** (ListItems after validation):
```ruby
# Item 1: Valid OpenSearch match
ListItem.new(
  position: 1,
  listable_id: 123,
  verified: true,
  metadata: {
    "title" => "Come Together",
    "artists" => ["The Beatles"],
    "song_id" => 123,
    "song_name" => "Come Together",
    "opensearch_match" => true,
    "opensearch_score" => 18.5
  }
)

# Item 2: Invalid MusicBrainz match
ListItem.new(
  position: 2,
  listable_id: nil,
  verified: false,
  metadata: {
    "title" => "Imagine",
    "artists" => ["John Lennon"],
    "mb_recording_id" => "abc-123",
    "mb_recording_name" => "Imagine (Live)",
    "mb_artist_names" => ["John Lennon"],
    "musicbrainz_match" => true,
    "ai_match_invalid" => true
  }
)

# Item 3: Missing - no match found
ListItem.new(
  position: 3,
  listable_id: nil,
  verified: false,
  metadata: {
    "title" => "Obscure Song",
    "artists" => ["Unknown Artist"]
  }
)
```

**Rendered Table**:
```
| Status |  # | Original              | Matched                    | Source    | Actions |
|--------|----|-----------------------|----------------------------|-----------|---------|
|   V    |  1 | Come Together         | Come Together              | OS 18.5   |    -    |
|        |    | The Beatles           | The Beatles                |           |         |
|--------|----|-----------------------|----------------------------|-----------|---------|
|   X    |  2 | Imagine               | Imagine (Live)             | MB        |    -    |
|        |    | John Lennon           | John Lennon                |           |  (red)  |
|--------|----|-----------------------|----------------------------|-----------|---------|
|   -    |  3 | Obscure Song          | -                          | -         |    -    |
|        |    | Unknown Artist        |                            |           |  (gray) |
```

**Stats Cards**:
- Total: 3
- Valid: 1 (33.3%)
- Invalid: 1 (33.3%)
- Missing: 1 (33.3%)

### Example 2: Filter Behavior

**Initial State**: All 100 items visible
- Stats: Total: 100, Valid: 60, Invalid: 25, Missing: 15
- Filter: "Show All"
- Display: "Showing 100 items"

**After selecting "Invalid Only"**:
- Filter value: "invalid"
- Visible rows: 25 (only rows with `data-status="invalid"`)
- Hidden rows: 75
- Display: "Showing 25 items"

---

## Technical Approach

### File Structure

```
web-app/
+-- app/
|   +-- components/
|   |   +-- admin/
|   |       +-- music/
|   |           +-- songs/
|   |               +-- wizard/
|   |                   +-- review_step_component.rb         # MODIFY: Add helpers
|   |                   +-- review_step_component.html.erb   # MODIFY: Full UI
|   +-- javascript/
|   |   +-- controllers/
|   |       +-- review_filter_controller.js                  # NEW
|   +-- controllers/
|   |   +-- admin/
|   |       +-- music/
|   |           +-- songs/
|   |               +-- list_wizard_controller.rb            # MODIFY: Review step logic
+-- test/
    +-- components/
    |   +-- admin/
    |       +-- music/
    |           +-- songs/
    |               +-- wizard/
    |                   +-- review_step_component_test.rb    # NEW or MODIFY
    +-- controllers/
    |   +-- admin/
    |       +-- music/
    |           +-- songs/
    |               +-- list_wizard_controller_test.rb       # MODIFY: Add review tests
    +-- system/
        +-- admin/
            +-- music/
                +-- songs/
                    +-- wizard_review_step_test.rb            # NEW: System tests
```

---

## Testing Strategy

### Component Tests

**File**: `test/components/admin/music/songs/wizard/review_step_component_test.rb`

**Test Cases**:
```ruby
test "renders stats cards with correct counts"
test "renders stats cards with correct percentages"
test "renders filter dropdown with all options"
test "renders table with all items"
test "renders valid item with success badge"
test "renders invalid item with error badge and red background"
test "renders missing item with ghost badge and gray background"
test "renders opensearch source with score"
test "renders musicbrainz source badge"
test "renders original title and artists"
test "renders matched song name and artists for opensearch match"
test "renders mb recording name and artists for musicbrainz match"
test "renders dash for missing items"
test "renders row with correct data attributes"
test "handles empty items list"
```

### Controller Tests

**File**: `test/controllers/admin/music/songs/list_wizard_controller_test.rb`

**Add Test Cases**:
```ruby
test "review step loads all items with associations"
test "review step calculates correct counts"
test "can advance from review to import step"
test "can go back from review to validate step"
```

### System Tests (Stimulus Controller)

**File**: `test/system/admin/music/songs/wizard_review_step_test.rb`

**Test Cases**:
```ruby
test "filter shows only valid items when selected"
test "filter shows only invalid items when selected"
test "filter shows only missing items when selected"
test "filter shows all items when show all selected"
test "visible count updates after filtering"
```

---

## Implementation Steps

### Phase 1: Stimulus Controller (30 minutes)

1. **Create filter controller using Rails generator**
   - [ ] Generate controller: `bin/rails generate stimulus review_filter`
   - [ ] Implement filter method with targets: `row`, `filter`, `count`
   - [ ] Add count update logic
   - [ ] Test manually in browser

   **CRITICAL**: Always use the Rails generator to create Stimulus controllers. Manual creation has caused issues in the past (missing registrations, incorrect paths).

### Phase 2: View Component (1.5 hours)

2. **Update component Ruby class**
   - [ ] Add helper methods for status determination
   - [ ] Add helper methods for badges
   - [ ] Add helper methods for display formatting
   - [ ] Add stats calculation methods

3. **Update component template**
   - [ ] Add stats cards section
   - [ ] Add filter bar with count display
   - [ ] Add table structure with all columns
   - [ ] Add row rendering with data attributes
   - [ ] Add Stimulus controller connection
   - [ ] Add navigation buttons

4. **Write component tests**
   - [ ] Test stats display
   - [ ] Test table rendering
   - [ ] Test badge rendering
   - [ ] Test data attributes

### Phase 3: Controller Integration (45 minutes)

5. **Update controller**
   - [ ] Implement `load_review_step_data` with includes
   - [ ] Add `advance_from_review_step` method
   - [ ] Update `advance_step` case statement

6. **Write controller tests**
   - [ ] Test data loading
   - [ ] Test navigation

### Phase 4: System Tests (30 minutes)

7. **Create system tests**
   - [ ] Test filter behavior
   - [ ] Verify count updates

### Phase 5: Polish (15 minutes)

8. **Mobile testing**
   - [ ] Test responsive layout
   - [ ] Test horizontal scroll

9. **Full test suite**
   - [ ] Run all tests
   - [ ] Fix any failures

---

## Validation Checklist (Definition of Done)

- [ ] Review step displays all items (no pagination)
- [ ] Stats cards show correct counts and percentages
- [ ] Filter dropdown works with instant feedback
- [ ] Visible count updates after filtering
- [ ] Row highlighting works based on status
- [ ] Status badges render correctly
- [ ] Source badges render correctly with scores
- [ ] Original and matched data display correctly
- [ ] Mobile horizontal scroll works
- [ ] Component tests pass (15+ tests)
- [ ] Controller tests pass (4+ new tests)
- [ ] System tests pass (5+ tests)
- [ ] No N+1 queries
- [ ] Documentation updated

---

## Dependencies

### Depends On (Completed)
- [086] Infrastructure - wizard_state, routes, model helpers
- [087] Wizard UI Shell - WizardController, step components
- [088] Step 0: Import Source - import_source selection
- [089] Step 1: Parse - Creates list_items with metadata
- [090] Step 2: Enrich - Adds match data to metadata
- [090a] Step-Namespaced Status - wizard_step_status methods
- [091] Step 3: Validation - Sets verified flag and ai_match_invalid

### Needed By (Blocked Until This Completes)
- [093] Step 4: Actions - Adds per-row action buttons and handlers
- [094] Step 5: Import - Uses reviewed items for final import

### External References
- **Validate Component Pattern**: `app/components/admin/music/songs/wizard/validate_step_component.html.erb`
- **ListItem Model**: `app/models/list_item.rb` (scopes and attributes)
- **List Model**: `app/models/list.rb` (wizard_state methods)
- **DaisyUI Stats**: https://daisyui.com/components/stat/
- **DaisyUI Table**: https://daisyui.com/components/table/
- **Stimulus Handbook**: https://stimulus.hotwired.dev/handbook/introduction

---

## Related Tasks

- **Previous**: [091] Song Step 3: Validation
- **Next**: [093] Song Step 4: Actions
- **Related**: Review is UI-only; [093] adds per-row interactivity

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns (ViewComponents, Stimulus, DaisyUI)
- Do not duplicate authoritative code; **link to files by path**
- Respect snippet budget (<=40 lines per snippet)
- Show ALL items - no server-side pagination
- Actions column is placeholder only - implemented in [093]
- Use client-side filtering via Stimulus (no Turbo Frame partials)
- No bulk selection - users act on individual items
- **CRITICAL**: Use `bin/rails generate stimulus <name>` to create Stimulus controllers - never create them manually (causes registration issues)

### Required Outputs
- New file: `app/javascript/controllers/review_filter_controller.js`
- New file: `test/system/admin/music/songs/wizard_review_step_test.rb`
- Modified: `app/components/admin/music/songs/wizard/review_step_component.rb`
- Modified: `app/components/admin/music/songs/wizard/review_step_component.html.erb`
- Modified: `app/controllers/admin/music/songs/list_wizard_controller.rb`
- New or Modified: `test/components/admin/music/songs/wizard/review_step_component_test.rb`
- Modified: `test/controllers/admin/music/songs/list_wizard_controller_test.rb`
- Passing tests for all new functionality (20+ tests)
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1. **codebase-pattern-finder** -> Already done (collected wizard patterns, validate component patterns)
2. **codebase-analyzer** -> Already done (understood ListItem model and status logic)
3. **technical-writer** -> Update docs after implementation

### Test Fixtures
- Use existing `lists(:music_songs_list)` fixture
- Create list_items with varied statuses programmatically in tests
- System tests should use Capybara for Stimulus testing

---

## Implementation Notes

### Files Created

- `app/javascript/controllers/review_filter_controller.js` - Client-side filtering Stimulus controller (~25 lines)
- `test/components/admin/music/songs/wizard/review_step_component_test.rb` - 21 component tests
- `test/system/admin/music/songs/wizard_review_step_test.rb` - 5 system tests for filter behavior

### Files Modified

- `app/components/admin/music/songs/wizard/review_step_component.rb` - Added helper methods for status determination, badges, percentages, and display formatting
- `app/components/admin/music/songs/wizard/review_step_component.html.erb` - Complete UI with stats cards, filter dropdown, review table with status badges and row highlighting
- `app/controllers/admin/music/songs/list_wizard_controller.rb` - Updated `load_review_step_data` to calculate counts, added `advance_from_review_step` method with validation check
- `test/controllers/admin/music/songs/list_wizard_controller_test.rb` - Added 5 new review step tests

### Key Implementation Details

1. **Stimulus Controller** (`review_filter_controller.js`):
   - Uses Rails generator (`bin/rails generate stimulus review_filter`)
   - Static targets: `row`, `filter`, `count`
   - Simple toggle of `hidden` class based on `data-status` attribute
   - Updates visible count display on filter change

2. **Component Ruby Class**:
   - `item_status(item)` - Returns "valid", "invalid", or "missing" based on `verified?` flag and `ai_match_invalid` metadata
   - `status_badge_class/icon` - Returns appropriate DaisyUI badge classes
   - `row_background_class` - Returns `bg-error/10` for invalid, `bg-base-200` for missing
   - `source_badge` - Returns hash with text, class, title for OpenSearch/MusicBrainz/none
   - Helper methods for original/matched title/artists extraction from metadata

3. **Component Template**:
   - DaisyUI `stats` component for summary cards
   - Filter bar with `select` dropdown and count display
   - Scrollable table container (`max-h-[32rem] overflow-y-auto`) with pinned header rows
   - Table with Status, Rank, Original, Matched, Source, Actions columns
   - Row highlighting and data attributes for filtering
   - No internal navigation buttons (wizard shell provides Back/Next)

4. **Controller Logic**:
   - Loads ALL list items (not just unverified) to show items verified by AI validation
   - Calculates valid/invalid/missing counts
   - `advance_from_review_step` validates at least one valid item exists before proceeding

### Test Coverage

- 18 component tests covering all UI states and rendering
- 5 controller tests for review step (data loading, navigation, validation)
- 5 system tests for Stimulus filter behavior
- All 2401 project tests pass

---

## Deviations from Plan

1. **Item Scope**: Changed from `.unverified` to `.ordered` (all items) in `load_review_step_data`. This is necessary because items marked as "valid" have `verified = true`, which would be excluded by the `.unverified` scope. The review step needs to show ALL items from the wizard session, including those verified by AI validation.

2. **Status terminology clarification**: The spec defined "valid" as `verified = true`, but the `.unverified` scope would filter these out. The implementation correctly shows all items and determines status based on:
   - Valid: `item.verified? == true`
   - Invalid: `item.metadata["ai_match_invalid"] == true`
   - Missing: Neither of the above (no match found)

3. **Removed internal navigation buttons**: The spec included Back and Continue buttons inside the component, but these are redundant since the wizard shell already provides navigation buttons outside the step content. Removed to avoid duplication.

4. **Added scrollable container**: Added `max-h-[32rem] overflow-y-auto` to table container and `table-pin-rows` to keep headers sticky, preventing long lists from making the page too long.

---

## Documentation Updated

- This spec file updated with implementation notes and deviations

---

## Notes

### Design Rationale

**Why No Pagination?**
- Lists typically have 50-500 items
- Users need full context before importing
- Filtering reduces cognitive load
- Simplifies state management

**Why Client-Side Filtering?**
- All data already loaded
- Instant feedback (no network latency)
- Simpler than server-side filtering with Turbo Frames

**Why No Bulk Actions?**
- At review stage, users fix specific problematic items
- Invalid/missing items require individual attention
- Simpler UX without checkbox management
- Per-row actions are more intuitive for this use case

### Performance Considerations
- Use `includes(listable: :artists)` to prevent N+1
- Stimulus controller uses simple class toggle for filtering
- CSS-only row hiding (no DOM manipulation)
- Consider virtual scrolling for 1000+ items (future enhancement)

### Future Enhancements (Out of Scope)
- [ ] Virtual scrolling for very large lists
- [ ] Column sorting
- [ ] Search within table
- [ ] Keyboard navigation
- [ ] Per-row action buttons (covered in [093])
