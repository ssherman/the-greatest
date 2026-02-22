# IGDB Search Match AI Task

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-02-21
- **Started**: 2026-02-21
- **Completed**: 2026-02-21
- **Developer**: AI Agent

## Overview

Improve IGDB match quality in the games list wizard enrichment step by adding an AI task that evaluates multiple IGDB search results and selects the best match. Currently, the enricher blindly takes the first IGDB result, which often returns the wrong game (e.g., searching "The Legend of Zelda" returns "Zelda II" first). The new AI task will evaluate up to 25 results and pick the best one — or indicate no good match exists.

**Scope**: IGDB fallback path in `Games::ListItemEnricher` only. OpenSearch matching (which uses score-based filtering) is out of scope.

**Non-goals**: Changing the OpenSearch enrichment path, modifying the IGDB API client, or altering the wizard UI.

## Context & Links
- Related feature: [List Wizard](/docs/features/list-wizard.md) — Games enrichment step
- Pattern to follow: [`AmazonProductMatchTask`](/web-app/app/lib/services/ai/tasks/amazon_product_match_task.rb) / [`AmazonGameMatchTask`](/web-app/app/lib/services/ai/tasks/games/amazon_game_match_task.rb)
- Current enricher: [`Services::Lists::Games::ListItemEnricher`](/web-app/app/lib/services/lists/games/list_item_enricher.rb)
- Base enricher: [`Services::Lists::BaseListItemEnricher`](/web-app/app/lib/services/lists/base_list_item_enricher.rb)
- IGDB search: [`Games::Igdb::Search::GameSearch`](/web-app/app/lib/games/igdb/search/game_search.rb)
- AI task base: [`Services::Ai::Tasks::BaseTask`](/web-app/app/lib/services/ai/tasks/base_task.rb)

## Interfaces & Contracts

### New Class: `Services::Ai::Tasks::Lists::Games::IgdbSearchMatchTask`

**File**: `app/lib/services/ai/tasks/lists/games/igdb_search_match_task.rb`

**Constructor**:
- `parent:` — the `List` record (for `AiChat` association)
- `search_query:` — the original search title string (e.g., "The Legend of Zelda")
- `search_results:` — array of IGDB result hashes (up to 25)
- `developers:` — optional array of developer name strings from metadata

**Provider/Model**: OpenAI, `gpt-5-mini`

**System message**: You are a video game expert. Given a search query and a list of IGDB search results, determine which result (if any) is the best match for the intended game.

**User prompt** includes:
- The search query (title) and optional developer names
- Numbered list of IGDB results with: name, first_release_date, cover image_id, developer names (extracted from involved_companies)

**Response schema** (OpenAI structured output):

```json
{
  "type": "object",
  "required": ["best_match_index", "confidence", "reasoning"],
  "properties": {
    "best_match_index": {
      "type": ["integer", "null"],
      "description": "0-based index of best matching result, or null if no good match"
    },
    "confidence": {
      "type": "string",
      "enum": ["high", "medium", "low", "none"],
      "description": "Confidence level in the match"
    },
    "reasoning": {
      "type": "string",
      "description": "Brief explanation of why this result was chosen or why none matched"
    }
  }
}
```

**Return value**: `Services::Ai::Result` with `data`:
```ruby
{
  best_match: igdb_result_hash_or_nil,
  best_match_index: integer_or_nil,
  confidence: "high"|"medium"|"low"|"none",
  reasoning: "string"
}
```

### Modified Class: `Services::Lists::Games::ListItemEnricher`

**File**: `app/lib/services/lists/games/list_item_enricher.rb`

Changes to `find_via_igdb`:
1. Increase `limit` from `5` to `25` in the `search_by_name` call
2. After receiving IGDB results, invoke `IgdbSearchMatchTask` with the results
3. If AI returns a match (`best_match_index` is not null and confidence is not `"none"`): use that result instead of `.first`
4. If AI returns no match: return `{success: false, source: :igdb, data: {}}`
5. Rest of the enrichment logic (check existing game, build enrichment_data, update list_item) stays the same but uses the AI-selected result
6. Store `ai_match_confidence` and `ai_match_reasoning` in the enrichment metadata

### Behaviors (pre/postconditions)

**Preconditions**:
- IGDB search returns at least 1 result (otherwise AI task is not invoked)
- List item has a valid title in metadata

**Postconditions**:
- If AI selects a match: list item metadata contains `igdb_id`, `igdb_name`, `igdb_match: true`, `ai_match_confidence`, `ai_match_reasoning`
- If AI says no match: enrichment returns `success: false` and list item is NOT updated
- An `AiChat` record is created for every AI invocation (parent = the List)

**Edge cases**:
- AI task fails (API error, timeout): fall back to current behavior (use first result) with a log warning. Do not let AI failures break the enrichment pipeline.
- IGDB returns only 1 result: still run through AI task (it may reject it as a bad match)
- Empty developer names: pass them as empty array; AI still evaluates by title match quality

### Non-Functionals
- **Performance**: Adds one AI API call per IGDB fallback. At gpt-5-mini speeds this should be <2s per item. Acceptable since enrichment is a background job.
- **Cost**: ~$0.001 per item (gpt-5-mini is very cheap). For a 500-item list where ~50% hit IGDB, that's ~$0.25.
- **Rate limiting**: No additional IGDB API calls (same search, just more results). OpenAI rate limits are generous.

## Acceptance Criteria

- [x] New `IgdbSearchMatchTask` class exists at `app/lib/services/ai/tasks/games/igdb_search_match_task.rb`
- [x] Task follows the `AmazonProductMatchTask` pattern (extends `BaseTask`, uses `OpenAI::BaseModel` for schema)
- [x] `ListItemEnricher#find_via_igdb` passes 25 results to AI task and uses the AI-selected result
- [x] When AI returns `best_match_index: null` or confidence `"none"`, enrichment returns `success: false`
- [x] When AI task raises an exception, enricher falls back to first result with a log warning
- [x] Enrichment metadata includes `ai_match_confidence` and `ai_match_reasoning` fields
- [x] Unit tests for `IgdbSearchMatchTask` (mocked OpenAI responses)
- [x] Unit tests for `ListItemEnricher` with AI matching (mocked task results)

### Golden Examples

```text
Input: search_query = "The Legend of Zelda"
       IGDB results = [
         {id: 1, name: "Zelda II: The Adventure of Link", first_release_date: 568598400},
         {id: 2, name: "The Legend of Zelda", first_release_date: 509328000},
         {id: 3, name: "The Legend of Zelda: Breath of the Wild", first_release_date: 1488499200},
         ...
       ]
Output: best_match_index = 1 (0-indexed → "The Legend of Zelda")
        confidence = "high"
        reasoning = "Exact title match with the original NES game"
```

```text
Input: search_query = "Super Obscure Indie Game That Doesn't Exist"
       IGDB results = [various unrelated games]
Output: best_match_index = null
        confidence = "none"
        reasoning = "None of the results match the search query"
```

---

## Agent Hand-Off

### Constraints
- Follow existing AI task patterns exactly (`AmazonProductMatchTask` / `AmazonGameMatchTask`)
- Use `OpenAI::BaseModel` for response schema (same as existing tasks)
- Do not modify `BaseListItemEnricher` — all changes in the games subclass
- Respect snippet budget (≤40 lines per snippet)
- Do not duplicate authoritative code; **link to file paths**

### Required Outputs
- Updated files (paths listed in "Key Files Touched")
- Passing tests for the Acceptance Criteria
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder → collect `AmazonGameMatchTask` and `ListItemsValidatorTask` patterns
2) codebase-analyzer → verify AI task lifecycle and enricher integration points
3) technical-writer → update list-wizard.md docs and cross-refs

### Test Seed / Fixtures
- Existing game fixtures for `Games::Game`
- Existing list/list_item fixtures
- Mocked IGDB search results (array of hashes)
- Mocked OpenAI responses (structured JSON matching schema)

---

## Implementation Notes (living)
- Approach taken: Extended `BaseTask` directly (not `AmazonProductMatchTask`) since the matching paradigm differs — select best from list vs. filter matches
- Important decisions:
  - Used confidence allowlist (`high`, `medium`, `low`) instead of denylist (`!= "none"`) for robustness against hallucinated confidence values
  - Instance vars `@ai_match_confidence` and `@ai_match_reasoning` initialized at top of `find_via_igdb` for clarity
  - AI task failure falls back to first IGDB result (original behavior) with a log warning
  - IGDB search limit increased from original spec's 10 to 25 after testing showed 10 was insufficient
  - IGDB autocomplete endpoint and frontend maxResults also bumped to 25 for consistency

### Key Files Touched (paths only)
- `app/lib/services/ai/tasks/games/igdb_search_match_task.rb` (new)
- `app/lib/services/lists/games/list_item_enricher.rb` (modified)
- `app/sidekiq/games/wizard_enrich_list_items_job.rb` (modified — enrichment_keys)
- `app/controllers/admin/games/list_items_actions_controller.rb` (modified — IGDB autocomplete limit)
- `app/javascript/controllers/autocomplete_controller.js` (modified — maxResults)
- `test/lib/services/ai/tasks/games/igdb_search_match_task_test.rb` (new)
- `test/lib/services/lists/games/list_item_enricher_test.rb` (modified)

### Challenges & Resolutions
- Review identified pre-existing stats bug in `WizardEnrichListItemsJob#update_stats` — failed IGDB lookups increment `igdb_matches` instead of `not_found`. Out of scope for this PR.

### Deviations From Plan
- Task placed in `Services::Ai::Tasks::Games` namespace (not `Lists::Games`) since it's a general IGDB match evaluator, not list-specific

## Acceptance Results
- 2026-02-21, AI Agent, 30 tests / 86 assertions passing

## Future Improvements
- Apply AI matching to OpenSearch results if IGDB-only proves insufficient
- Consider caching AI decisions for repeated searches with same results
- Potentially use AI matching for music domain enrichment as well

## Related PRs
-

## Documentation Updated
- [ ] `docs/features/list-wizard.md` — update Games enricher section to mention AI matching (TODO)
- [x] Class docs on new task file
