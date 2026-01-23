# List Wizard Batch Processing for Large Lists

## Status
- **Status**: Implemented
- **Priority**: High
- **Created**: 2026-01-22
- **Started**: 2026-01-22
- **Completed**: 2026-01-22
- **Developer**: Claude

## Overview

Add optional batch processing to the list wizard parse and validate steps to handle large lists (1000+ items) reliably. Currently, when processing lists with 1000+ items, the AI returns incomplete results (e.g., only 100-343 items out of 1000) because it gets overwhelmed by large inputs. This spec addresses the issue by allowing users to opt into batch processing for large plain text lists.

**Scope**:
- Add "Process in batches" checkbox to source step UI
- Parse step: If batch mode enabled, split by lines and process in batches of 100
- Validate step: If batch mode enabled, batch enriched items into groups of 100

**Non-goals**:
- Auto-detecting when to batch (user decides)
- Batching HTML content (structure is too unpredictable)
- Adding retry logic for AI failures (separate concern)

## Context & Links

- **Related feature doc**: [`docs/features/list-wizard.md`](/docs/features/list-wizard.md)
- **Parse job**: [`app/sidekiq/music/base_wizard_parse_list_job.rb`](/web-app/app/sidekiq/music/base_wizard_parse_list_job.rb)
- **Validate job**: [`app/sidekiq/music/base_wizard_validate_list_items_job.rb`](/web-app/app/sidekiq/music/base_wizard_validate_list_items_job.rb)
- **Parser task**: [`app/lib/services/ai/tasks/lists/base_raw_parser_task.rb`](/web-app/app/lib/services/ai/tasks/lists/base_raw_parser_task.rb)
- **Validator task (songs)**: [`app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb`](/web-app/app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb)

## Interfaces & Contracts

### Domain Model (diffs only)

No database migration required. Batch mode preference stored in `wizard_state` JSONB column.

### UI Changes

#### Source Step Checkbox

Add checkbox to the source step (where user selects import method and pastes content):

| Element | Details |
|---------|---------|
| **Checkbox** | "Process in batches" |
| **Description** | "Enable for large plain text lists with one item per line (recommended for 500+ items). Processes 100 items at a time to ensure all items are captured." |
| **Default** | Unchecked |
| **Storage** | `wizard_state.batch_mode = true/false` |

**Placement**: Below the HTML/text input area, above the "Start Import" button.

### wizard_state Schema Addition

```json
{
  "batch_mode": false,
  "current_step": 0,
  "import_source": "custom_html",
  "steps": { ... }
}
```

### Behavioral Rules

#### Parse Step Batching

**Preconditions**:
- `@list.simplified_html` is present
- `wizard_state.batch_mode` is set

**Flow by Batch Mode**:

| Batch Mode | Behavior |
|------------|----------|
| `false` (default) | Single-pass (existing behavior) |
| `true` | Batch processing - split by lines, process 100 at a time |

**Batch Processing Flow** (when `batch_mode: true`):
1. Split `simplified_html` by newlines
2. Filter out empty/whitespace-only lines
3. Group into batches of 100 lines
4. For each batch:
   - Create temporary list-like object with batch content
   - Call `parser_task_class.new(parent: temp_list).call`
   - Collect parsed items
5. Combine all batch results with cumulative positions
6. Insert all items via single `ListItem.insert_all`

**Position Calculation**:
- Batch 1 (lines 1-100): positions 1-100
- Batch 2 (lines 101-200): positions 101-200
- If AI extracts explicit rank from content, use that; otherwise use line-based position

**Postconditions**:
- All non-empty lines have been processed
- `ListItem` records created with correct positions
- `wizard_state.steps.parse.status` = "completed"
- `wizard_state.steps.parse.metadata.total_items` = actual count

#### Validate Step Batching

**Preconditions**:
- Parse step completed
- `enriched_items` contains items with matches (listable_id, entity_id, or MB ID)
- `wizard_state.batch_mode` is set

**Flow by Batch Mode**:

| Batch Mode | Item Count | Behavior |
|------------|------------|----------|
| `false` | Any | Single-pass (existing behavior) |
| `true` | 0 items | Complete immediately with zero counts |
| `true` | >0 items | Batch processing (100 items per batch) |

**Batch Processing Flow** (when `batch_mode: true`):
1. Load all enriched items: `@items = enriched_items`
2. Split into batches of 100: `@items.each_slice(100)`
3. For each batch (with offset tracking):
   - Call `validator_task_class.new(parent: batch_context).call`
   - Map AI's local indices (1-100) to global indices using offset
   - Update items immediately (mark invalid, set verified)
   - Accumulate counts
4. Complete job with aggregated totals

**Index Mapping**:
- Batch 1: AI returns `[3, 7]` → global indices `[3, 7]`
- Batch 2: AI returns `[3, 7]` → global indices `[103, 107]` (offset=100)

**Postconditions**:
- All enriched items validated
- Invalid items have `metadata["ai_match_invalid"] = true`
- Valid items have `verified = true`
- `wizard_state.steps.validate.metadata` contains aggregated counts

### Error Handling

**Batch Failure Policy**: Fail entire step if any batch fails

| Scenario | Behavior |
|----------|----------|
| Batch N fails | Stop processing, mark step as "failed", re-raise for Sidekiq retry |
| All batches succeed | Mark step as "completed" with aggregated metadata |

**Rationale**: Partial success would leave data in inconsistent state. Fail-fast is safer.

### Non-Functionals

- **Memory**: Process batches sequentially to avoid loading all results simultaneously
- **Idempotency**: Existing `destroy_all` (parse) and `clear_previous_validation_flags` (validate) ensure re-runs are safe
- **Progress UI**: No changes - keep simple "Processing..." display

## Acceptance Criteria

### UI
- [x] Source step shows "Process in batches" checkbox
- [x] Checkbox has descriptive help text explaining when to use it
- [x] Checkbox state is saved to `wizard_state.batch_mode`
- [x] Checkbox defaults to unchecked

### Parse Step
- [x] Batch mode OFF: Works exactly as before (no regression)
- [x] Batch mode ON with 150 lines → creates 150 ListItems (not truncated)
- [x] Batch mode ON with 1000 lines → creates 1000 ListItems with correct positions
- [x] Empty lines in plain text are skipped (don't count toward batch size)
- [x] Positions are cumulative: batch 1 = 1-100, batch 2 = 101-200

### Validate Step
- [x] Batch mode OFF: Works exactly as before (no regression)
- [x] Batch mode ON with 200 enriched items → all validated, counts aggregated correctly
- [x] Invalid indices mapped correctly across batches
- [x] Items updated after each batch (not held in memory)

### Error Handling
- [x] If batch 3 of 10 fails → entire step fails, wizard_state shows error
- [x] Failed step can be re-run (idempotent)

### Golden Examples

**Parse: Plain Text Input (250 lines)**
```text
Input: 250 non-empty lines of "RANK / ARTIST / TITLE" format
Processing:
  - Batch 1: lines 1-100 → parse → items with positions 1-100
  - Batch 2: lines 101-200 → parse → items with positions 101-200
  - Batch 3: lines 201-250 → parse → items with positions 201-250
Output: 250 ListItem records, wizard_state.metadata.total_items = 250
```

**Validate: 350 Enriched Items**
```text
Input: 350 enriched items (have matches from enrich step)
Processing:
  - Batch 1: items 1-100 → validate → 90 valid, 10 invalid
  - Batch 2: items 101-200 → validate → 85 valid, 15 invalid
  - Batch 3: items 201-300 → validate → 95 valid, 5 invalid
  - Batch 4: items 301-350 → validate → 48 valid, 2 invalid
Output: wizard_state.metadata = {valid_count: 318, invalid_count: 32, ...}
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture
- All batching logic in job layer (not in AI tasks)
- Keep AI task interface unchanged
- Respect snippet budget (≤40 lines per snippet)
- Do not duplicate authoritative code; **link to file paths**

### Required Outputs
- Updated files (paths listed in "Key Files Touched")
- Passing tests for the Acceptance Criteria
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder → verify existing job patterns for iteration/batching
2) codebase-analyzer → confirm AI task interface and Result object structure
3) technical-writer → update `docs/features/list-wizard.md` with batch processing details

### Test Seed / Fixtures
- Plain text fixture: 150+ lines in "RANK / ARTIST / TITLE" format
- HTML fixture: existing test fixtures should work
- ListItems: Create 200+ enriched items for validate batch testing

---

## Implementation Notes (living)

### Approach
- Add "Process in batches" checkbox to source step component
- Store `batch_mode` in wizard_state when advancing from source step
- Add private methods to `BaseWizardParseListJob` for batching (when enabled)
- Add private methods to `BaseWizardValidateListItemsJob` for item batching (when enabled)
- Use `OpenStruct` or simple class for temporary list-like objects in parse batches

### Key Implementation Details

#### Line Splitting (reference, ≤40 lines)
```ruby
# reference only - add to BaseWizardParseListJob
def split_into_batches(content, batch_size: 100)
  lines = content.split("\n").reject { |line| line.strip.empty? }
  lines.each_slice(batch_size).map { |batch| batch.join("\n") }
end
```

#### Parser Task Content Override (reference, ≤40 lines)
```ruby
# reference only - BaseRawParserTask accepts optional content parameter
def initialize(parent:, content: nil, provider: nil, model: nil)
  @provided_content = content
  super(parent: parent, provider: provider, model: model)
end

def content_to_parse
  @provided_content || parent.simplified_html
end
```

#### Check Batch Mode (reference, ≤40 lines)
```ruby
# reference only - add to both jobs
def batch_mode?
  @list.wizard_state&.dig("batch_mode") == true
end
```

### Key Files Touched (paths only)

**UI Components** (checkbox in base, inherited by songs/albums):
- `app/components/admin/music/wizard/base_source_step_component.rb`
- `app/components/admin/music/wizard/base_source_step_component.html.erb`

**Controllers**:
- `app/controllers/admin/music/base_list_wizard_controller.rb` (save batch_mode to wizard_state)

**Jobs**:
- `app/sidekiq/music/base_wizard_parse_list_job.rb`
- `app/sidekiq/music/base_wizard_validate_list_items_job.rb`

**Tests** (updated with batch mode tests):
- `test/sidekiq/music/songs/wizard_parse_list_job_test.rb`
- `test/sidekiq/music/songs/wizard_validate_list_items_job_test.rb`
- `test/components/admin/music/songs/wizard/source_step_component_test.rb`

**AI Tasks** (added content:/items: parameters for batch processing):
- `app/lib/services/ai/tasks/lists/base_raw_parser_task.rb` (added content: parameter)
- `app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb` (added items: parameter)
- `app/lib/services/ai/tasks/lists/music/albums/list_items_validator_task.rb` (added items: parameter)

### Challenges & Resolutions
- **Mocha test stubbing**: `stubs(:call).returns do ... end` block syntax doesn't work in Mocha. Resolved by using `.returns(result1).then.returns(result2)` chain for sequential returns.
- **Error message preservation**: Initial implementation raised generic "Batch parsing failed" which overwrote the detailed error stored via handle_error. Resolved by including batch number in the raised error message.
- **Polymorphic parent association**: Initial `BatchContent` struct couldn't be used as parent for `AiChat` (polymorphic association requires `has_query_constraints?` method). Resolved by adding `content:` parameter to parser task instead of using a struct as parent.
- **Scoped order warning in find_each**: Validate job's `clear_previous_validation_flags` triggered Rails warning about ignored order scope. Resolved by adding `.reorder(nil)` before `find_each`.

### Deviations From Plan
- **Removed BatchContent struct entirely**: Initial plan used a `BatchContent` struct as a temporary list-like object for batch parsing. However, the AI task creates an `AiChat` with polymorphic `parent` association, which requires `has_query_constraints?` method. Instead of adding complexity to the struct, we added a `content:` parameter to `BaseRawParserTask` that overrides the content while keeping the real list as the parent.
- **Parser task content parameter**: Added `content:` parameter to `BaseRawParserTask#initialize`. When provided, uses that content instead of `parent.simplified_html` and skips updating `parent.items_json` in persist.
- **Validator task items parameter**: Added `items:` parameter to validator tasks to support batch processing, keeping ai_chat associated with parent list as requested.

## Acceptance Results
- Date: 2026-01-23
- Verifier: Tests (29 tests, 80 assertions, 0 failures for batch-related tests)
- All batch mode tests pass for parse and validate jobs
- Manual testing confirmed batch processing works for large lists
- StandardRB linting passes

## Future Improvements
- If batching needed elsewhere, extract to reusable service classes
- Consider adding batch-level progress to UI if users request it
- Retry logic for individual AI calls (separate spec)

## Related PRs
- TBD

## Documentation Updated
- [x] `docs/features/list-wizard.md` - Added batch processing section
- [x] Class docs updated in job file headers
- [x] BaseRawParserTask header updated with content: parameter docs
