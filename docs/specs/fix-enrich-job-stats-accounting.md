# Fix Enrichment Job Stats Accounting Bug

## Status
- **Status**: Not Started
- **Priority**: Low
- **Created**: 2026-02-21
- **Started**:
- **Completed**:
- **Developer**: AI Agent

## Overview

Fix a stats accounting bug in wizard enrich jobs where failed enrichment lookups are counted as successful matches. When an enricher returns `{success: false, source: :igdb}` (or `:musicbrainz`, `:opensearch`), `update_stats` routes by `:source` only, ignoring `:success`, so the failure is tallied as a match instead of `not_found`.

**Scope**: All `update_stats` implementations in enrich jobs.

**Non-goals**: Changing enricher return values or the base job orchestration logic.

## Context & Links
- Base job: [`BaseWizardEnrichListItemsJob`](/web-app/app/sidekiq/base_wizard_enrich_list_items_job.rb)
- Games job: [`Games::WizardEnrichListItemsJob`](/web-app/app/sidekiq/games/wizard_enrich_list_items_job.rb)
- Music base job: [`Music::BaseWizardEnrichListItemsJob`](/web-app/app/sidekiq/music/base_wizard_enrich_list_items_job.rb)
- Games enricher: [`Services::Lists::Games::ListItemEnricher`](/web-app/app/lib/services/lists/games/list_item_enricher.rb)
- Music enricher: [`Services::Lists::Music::BaseListItemEnricher`](/web-app/app/lib/services/lists/music/base_list_item_enricher.rb)
- Discovered during: [IGDB Search Match AI Task](/docs/specs/igdb-search-match-ai-task.md) code review

## Interfaces & Contracts

### Enricher Result Hash (existing contract, unchanged)
```ruby
{success: true|false, source: :opensearch|:igdb|:musicbrainz|:not_found|:error, data: {}}
```

### Behaviors (pre/postconditions)

**Current (buggy)**:
- `update_stats` routes solely on `result[:source]`
- A failed IGDB lookup (`{success: false, source: :igdb}`) increments `igdb_matches`
- A failed MusicBrainz lookup (`{success: false, source: :musicbrainz}`) increments `musicbrainz_matches`
- A failed OpenSearch lookup (`{success: false, source: :opensearch}`) falls through to `else` → `not_found` (accidentally correct)

**Fixed (postcondition)**:
- `update_stats` checks `result[:success]` first
- Only successful results increment match counters
- All failed results increment `not_found`

### Non-Functionals
- No performance impact — this is a simple conditional check in a background job
- Stats are used for progress display in the wizard UI, so accuracy matters for user experience

## Acceptance Criteria

- [ ] `Games::WizardEnrichListItemsJob#update_stats` checks `result[:success]` before counting matches
- [ ] `Music::BaseWizardEnrichListItemsJob#update_stats` checks `result[:success]` before counting matches
- [ ] Failed enrichments with `source: :igdb` increment `not_found`, not `igdb_matches`
- [ ] Failed enrichments with `source: :musicbrainz` increment `not_found`, not `musicbrainz_matches`
- [ ] Successful enrichments still increment the correct match counter
- [ ] Unit tests for both jobs verify correct stats for success and failure cases

### Golden Examples

```text
Input:  result = {success: false, source: :igdb, data: {}}
Before: @stats[:igdb_matches] += 1  (wrong)
After:  @stats[:not_found] += 1     (correct)

Input:  result = {success: true, source: :igdb, game_id: 42, data: {...}}
Before: @stats[:igdb_matches] += 1  (correct, unchanged)
After:  @stats[:igdb_matches] += 1  (correct, unchanged)
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.
- Consider extracting the success check into `BaseWizardEnrichListItemsJob#enrich_item` if cleaner than duplicating in each subclass.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests for the Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → check if any other jobs have similar `update_stats` patterns
2) codebase-analyzer → verify all enricher return values and source symbols

### Test Seed / Fixtures
- Existing list fixtures for games and music
- No new fixtures needed — tests mock enricher results

---

## Implementation Notes (living)
- Approach taken:
- Important decisions:

### Key Files Touched (paths only)
- `app/sidekiq/games/wizard_enrich_list_items_job.rb` (modified)
- `app/sidekiq/music/base_wizard_enrich_list_items_job.rb` (modified)
- Tests for both jobs (new or modified)

### Challenges & Resolutions
-

### Deviations From Plan
-

## Acceptance Results
- Date, verifier, artifacts (screenshots/links):

## Future Improvements
- Consider moving `update_stats` success-checking into `BaseWizardEnrichListItemsJob#enrich_item` so subclasses only define the source-to-stat mapping

## Related PRs
-

## Documentation Updated
- [ ] Class docs on modified job files
