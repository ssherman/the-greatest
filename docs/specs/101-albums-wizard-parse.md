# 101 - Albums Wizard Parse Step

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-12-27
- **Started**: 2025-12-28
- **Completed**: 2025-12-28
- **Developer**: Claude

## Overview
Implement the parse step for the Albums List Wizard. This step takes raw HTML from a list source, uses AI to extract album information, and creates ListItem records with metadata.

**Goal**: Parse raw HTML into structured album data stored as ListItems.
**Scope**: Parse step component, background job, HTML save action.
**Non-goals**: Enrichment with MusicBrainz data (handled in spec 102).

## Context & Links
- Prerequisite: spec 100 (infrastructure)
- Songs parse job reference: `app/sidekiq/music/songs/wizard_parse_list_job.rb`
- Albums AI parser (exists): `app/lib/services/ai/tasks/lists/music/albums_raw_parser_task.rb`

## Interfaces & Contracts

### Controller Actions (add to ListWizardController)

| Action | Purpose |
|--------|---------|
| `save_html` | Save raw HTML from form input, trigger parse job |
| `reparse` | Re-trigger parse job on existing HTML |

### Background Job: Music::Albums::WizardParseListJob

```ruby
# app/sidekiq/music/albums/wizard_parse_list_job.rb
class Music::Albums::WizardParseListJob
  include Sidekiq::Job

  def perform(list_id)
    @list = Music::Albums::List.find(list_id)
    # 1. Validate raw_html present
    # 2. Update step status to "running"
    # 3. Destroy existing unverified list items
    # 4. Call AlbumsRawParserTask
    # 5. Create ListItem records from parsed albums
    # 6. Update step status to "completed" with metadata
  end
end
```

### Step Component: ParseStepComponent

```ruby
# app/components/admin/music/albums/wizard/parse_step_component.rb
class Admin::Music::Albums::Wizard::ParseStepComponent < ViewComponent::Base
  def initialize(list:, errors: nil, raw_html_preview: nil, parsed_count: 0)
    @list = list
    @errors = errors
    @raw_html_preview = raw_html_preview
    @parsed_count = parsed_count
  end
end
```

### ListItem Metadata Schema (after parsing)

```json
{
  "title": "Album Title",
  "artists": ["Artist Name"],
  "release_year": 1973,
  "rank": 1
}
```

### Behaviors (pre/postconditions)

**Preconditions:**
- List exists with `import_source: "custom_html"` in wizard_state
- For MusicBrainz series import, parse step is skipped

**Postconditions:**
- `raw_html` saved to list record
- ListItem records created with `listable_type: nil` (unlinked)
- `metadata` JSONB populated with parsed album data
- `position` set based on rank or order in list
- Step status updated to "completed" with item count

**Edge cases:**
- Empty HTML input: job fails with error message
- Malformed HTML: AI parser handles gracefully, may return fewer items
- Duplicate albums in list: each becomes separate ListItem

### Non-Functionals
- Parse job should complete in < 60 seconds for lists up to 500 items
- Progress updates every 10% of parsing
- Job is idempotent (destroys unverified items before creating)

## Acceptance Criteria
- [x] Parse step component renders HTML textarea form
- [x] Saving HTML triggers WizardParseListJob
- [x] Job updates progress via wizard_state
- [x] Polling UI shows progress percentage
- [x] Completed parse shows count of extracted albums
- [x] "Reparse" button triggers job again
- [x] ListItems created with correct metadata
- [x] Skipped for MusicBrainz series import path

### Golden Examples

**Input HTML:**
```html
<ol>
  <li>1. The Dark Side of the Moon - Pink Floyd (1973)</li>
  <li>2. Abbey Road - The Beatles (1969)</li>
</ol>
```

**Resulting ListItems:**
```ruby
ListItem.create!(
  list: list,
  position: 1,
  metadata: {
    "title" => "The Dark Side of the Moon",
    "artists" => ["Pink Floyd"],
    "release_year" => 1973,
    "rank" => 1
  }
)
```

---

## Agent Hand-Off

### Constraints
- Follow songs wizard parse job pattern exactly
- Reuse existing `AlbumsRawParserTask` (do not create new AI task)
- Use sidekiq generator for job creation

### Required Outputs
- `app/sidekiq/music/albums/wizard_parse_list_job.rb`
- `app/components/admin/music/albums/wizard/parse_step_component.rb`
- `app/components/admin/music/albums/wizard/parse_step_component.html.erb`
- Controller actions: `save_html`, `reparse`
- Test files for job and component

### Sub-Agent Plan
1) codebase-analyzer → Review songs parse job implementation
2) codebase-pattern-finder → Verify AlbumsRawParserTask usage pattern

### Test Seed / Fixtures
- List with sample `raw_html` content
- List with empty `raw_html` for error case

---

## Implementation Notes (living)
- Approach taken: Followed songs wizard parse job pattern exactly as specified
- Important decisions: Used Rails sidekiq generator for job creation; controller actions (save_html, reparse) were already implemented in spec 100

### Key Files Touched (paths only)
- `app/sidekiq/music/albums/wizard_parse_list_job.rb`
- `app/components/admin/music/albums/wizard/parse_step_component.rb`
- `app/components/admin/music/albums/wizard/parse_step_component.html.erb`
- `app/helpers/admin/music/albums/list_wizard_helper.rb`
- `test/sidekiq/music/albums/wizard_parse_list_job_test.rb`
- `test/components/admin/music/albums/wizard/parse_step_component_test.rb`

### Challenges & Resolutions
- None encountered - songs wizard provided clear patterns to follow

### Deviations From Plan
- Controller actions were already implemented in spec 100, so no controller changes needed

## Acceptance Results
- Date: 2025-12-28
- Verifier: Claude
- All 35 tests pass (19 new parse step tests + 16 controller tests)

## Future Improvements
- Consider extracting shared parse job logic between songs and albums

## Related PRs
-

## Documentation Updated
- [x] Spec file updated with implementation details
