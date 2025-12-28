# 103 - Albums Wizard Validate Step

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-12-27
- **Started**:
- **Completed**:
- **Developer**:

## Overview
Implement the validate step for the Albums List Wizard. This step uses AI to validate that enrichment matches are correct, flagging invalid matches for manual review.

**Goal**: AI-assisted validation of album matches to catch errors before import.
**Scope**: Validate step component, background job, AI validation task.
**Non-goals**: Manual review interface (handled in spec 104).

## Context & Links
- Prerequisite: spec 100, 101, 102
- Songs validator reference: `app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb`
- Songs validate job: `app/sidekiq/music/songs/wizard_validate_list_items_job.rb`

## Interfaces & Contracts

### Background Job: Music::Albums::WizardValidateListItemsJob

```ruby
# app/sidekiq/music/albums/wizard_validate_list_items_job.rb
class Music::Albums::WizardValidateListItemsJob
  include Sidekiq::Job

  def perform(list_id)
    # 1. Load list and enriched items
    # 2. Update step status to "running"
    # 3. Clear previous validation flags if re-validating
    # 4. Call ListItemsValidatorTask with enriched items
    # 5. Mark invalid items in metadata
    # 6. Mark valid items as verified
    # 7. Update step status to "completed" with stats
  end
end
```

### AI Task: Services::Ai::Tasks::Lists::Music::Albums::ListItemsValidatorTask

```ruby
# app/lib/services/ai/tasks/lists/music/albums/list_items_validator_task.rb
module Services::Ai::Tasks::Lists::Music::Albums
  class ListItemsValidatorTask < Services::Ai::Tasks::BaseTask
    # Validates album matches by comparing:
    # - Album title similarity
    # - Artist name matches
    # - Release year proximity
    # - Detects: compilations vs studio albums, live albums, remasters, deluxe editions
  end
end
```

### Step Component: ValidateStepComponent

```ruby
# app/components/admin/music/albums/wizard/validate_step_component.rb
class Admin::Music::Albums::Wizard::ValidateStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  # Expose: valid_count, invalid_count, verified_count, items_to_validate
  # Status helpers: idle_or_failed?, running?, completed?, failed?
end
```

### ListItem Metadata Schema (after validation)

**Valid match (auto-verified):**
```json
{
  "title": "The Dark Side of the Moon",
  "artists": ["Pink Floyd"],
  "album_id": 123,
  "opensearch_match": true,
  "verified": true
}
```
Note: `verified` boolean on ListItem model set to `true`

**Invalid match (flagged):**
```json
{
  "title": "Dark Side of the Moon",
  "artists": ["Pink Floyd"],
  "mb_release_group_id": "abc123",
  "mb_release_group_name": "The Dark Side of the Moon (Live)",
  "ai_match_invalid": true,
  "ai_invalid_reason": "Matched to live album instead of studio album"
}
```

### AI Validation Prompt Template

```text
You are validating album matches from a "best albums" list import.

For each album, compare the ORIGINAL entry with the MATCHED album:
- Title should match (ignoring case, minor formatting)
- Artists should match
- Year should be close (within 1-2 years for different editions)

INVALID matches include:
- Live albums when studio album was intended
- Greatest Hits/Compilations when studio album was intended
- Deluxe/Remastered editions when original was intended
- Different albums with similar names
- Tribute albums or covers

Return an array of item numbers that are INVALID matches.
```

### Behaviors (pre/postconditions)

**Preconditions:**
- Enrich step completed
- Items have enrichment data (either `listable_id` or `mb_release_group_id`)

**Postconditions:**
- Items with valid matches have `verified: true`
- Items with invalid matches have `ai_match_invalid: true` in metadata
- Invalid items have `listable_id` cleared (if was set)
- Step metadata includes validation counts and sample reasoning

**Edge cases:**
- Items without enrichment data: skipped (not validated)
- AI returns unexpected format: job fails gracefully
- Re-validating: clears previous flags before running

### Non-Functionals
- Validate job should complete in < 2 minutes for 100 items
- Batch items to AI in groups of 20-50 for efficiency
- Single AI call per batch (not per item)

## Acceptance Criteria
- [ ] Validate step component shows job progress
- [ ] Job validates all enriched items via AI
- [ ] Valid matches automatically verified
- [ ] Invalid matches flagged with reason
- [ ] Stats show valid/invalid/skipped counts
- [ ] "Re-validate" button clears and re-runs validation
- [ ] Validation reasons visible in review step

### Golden Examples

**AI Input (batch):**
```json
{
  "items": [
    {
      "number": 1,
      "original_title": "Dark Side of the Moon",
      "original_artists": ["Pink Floyd"],
      "matched_title": "The Dark Side of the Moon (Live)",
      "matched_artists": ["Pink Floyd"],
      "matched_year": 1995
    }
  ]
}
```

**AI Output:**
```json
{
  "invalid_matches": [1],
  "reasoning": "Item 1: Matched to 1995 live recording instead of 1973 studio album"
}
```

---

## Agent Hand-Off

### Constraints
- Follow songs ListItemsValidatorTask pattern
- Use same AI model/parameters as songs validator
- Batch processing for efficiency

### Required Outputs
- `app/sidekiq/music/albums/wizard_validate_list_items_job.rb`
- `app/lib/services/ai/tasks/lists/music/albums/list_items_validator_task.rb`
- `app/components/admin/music/albums/wizard/validate_step_component.rb`
- `app/components/admin/music/albums/wizard/validate_step_component.html.erb`
- Test files for all new classes

### Sub-Agent Plan
1) codebase-analyzer → Review songs ListItemsValidatorTask implementation
2) codebase-pattern-finder → Find AI task patterns in project

### Test Seed / Fixtures
- ListItems with enrichment data (both valid and invalid matches)

---

## Implementation Notes (living)
- Approach taken:
- Important decisions:

### Key Files Touched (paths only)
- `app/sidekiq/music/albums/wizard_validate_list_items_job.rb`
- `app/lib/services/ai/tasks/lists/music/albums/list_items_validator_task.rb`
- `app/components/admin/music/albums/wizard/validate_step_component.rb`
- `app/helpers/admin/music/albums/list_wizard_helper.rb`

### Challenges & Resolutions
-

### Deviations From Plan
-

## Acceptance Results
- Date, verifier, artifacts:

## Future Improvements
- Consider extracting base validator task between songs and albums
- Could add confidence scores instead of binary valid/invalid

## Related PRs
-

## Documentation Updated
- [ ] Class docs for new files
