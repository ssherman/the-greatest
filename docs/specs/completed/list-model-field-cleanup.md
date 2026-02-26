# List Model Field Cleanup

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-02-25
- **Started**: 2026-02-25
- **Completed**: 2026-02-25
- **Developer**: Claude

## Overview
Clean up the `lists` table by removing the unused `formatted_text` column, renaming `raw_html` → `raw_content` and `simplified_html` → `simplified_content` to reflect actual usage (both HTML and plain text), and making `simplified_content` read-only in admin forms (auto-generated from `raw_content` via `SimplifierService`).

Additionally, `items_json` was made read-only in admin forms (display-only `<pre>` block, removed from permitted params) and field order was improved so `raw_content` and `simplified_content` appear above `items_json`.

**Non-goals**: No changes to the AI parsing pipeline logic itself.

## Context & Links
- Source model: `web-app/app/models/list.rb`
- SimplifierService: `web-app/app/lib/services/html/simplifier_service.rb`
- Admin base controller: `web-app/app/controllers/admin/lists_base_controller.rb`
- Wizard controller concern: `web-app/app/controllers/concerns/base_list_wizard_controller.rb`
- Public list controller: `web-app/app/controllers/music/lists_controller.rb`

## Interfaces & Contracts

### Domain Model (diffs only)

**Migration 1: Remove `formatted_text`**
- `remove_column :lists, :formatted_text, :text`

**Migration 2: Rename columns**
- `rename_column :lists, :raw_html, :raw_content`
- `rename_column :lists, :simplified_html, :simplified_content`

Both migrations should be separate files for clean rollback.

### Behaviors (pre/postconditions)

**`raw_content` (renamed from `raw_html`)**
- Preconditions: No change — stores raw HTML or plain text from admin, wizard, or public forms
- Postconditions: When saved with changes, triggers `before_save` callback to auto-generate `simplified_content`

**`simplified_content` (renamed from `simplified_html`)**
- Preconditions: Auto-generated when `raw_content` changes, but also manually editable by admins
- Postconditions: Populated by `SimplifierService.call(raw_content)` whenever `raw_content` changes. Manual edits to `simplified_content` alone persist (callback only fires on `raw_content` change)
- No behavior change: Keep editable in admin forms, keep in permitted params

**`formatted_text` (removed)**
- No business logic references exist — safe to drop entirely

## Files To Update

### Migration files (create new)
- `db/migrate/TIMESTAMP_remove_formatted_text_from_lists.rb`
- `db/migrate/TIMESTAMP_rename_html_columns_on_lists.rb`

### Model layer
- `app/models/list.rb` — Rename `raw_html` → `raw_content`, `simplified_html` → `simplified_content` in callbacks, private methods. Remove `formatted_text` from schema annotation
- `app/models/books/list.rb` — Update schema annotations
- `app/models/games/list.rb` — Update schema annotations
- `app/models/movies/list.rb` — Update schema annotations
- `app/models/music/albums/list.rb` — Update schema annotations
- `app/models/music/songs/list.rb` — Update schema annotations

### Controller layer
- `app/controllers/admin/lists_base_controller.rb` — Rename `raw_html` → `raw_content` and `simplified_html` → `simplified_content` in permitted params. Remove `formatted_text` and `items_json` from permitted params
- `app/controllers/concerns/base_list_wizard_controller.rb` — Rename `raw_html` → `raw_content` (line 40: `update!`, line 128: `truncate`)
- `app/controllers/music/lists_controller.rb` — Rename `raw_html` → `raw_content` in permitted params (line 81)

### Service layer
- `app/lib/services/lists/import_service.rb` — Rename `simplified_html` → `simplified_content` (lines 15, 18-19)
- `app/lib/services/ai/tasks/lists/base_raw_parser_task.rb` — Rename `simplified_html` → `simplified_content` (line 63)

### Job layer
- `app/sidekiq/base_wizard_parse_list_job.rb` — Rename `raw_html` → `raw_content` (line 23), `simplified_html` → `simplified_content` (line 117)

### View layer — Admin show pages (update field names, keep display)
- `app/views/admin/games/lists/show.html.erb` — Rename labels/field refs. Remove `formatted_text` section
- `app/views/admin/music/songs/lists/show.html.erb` — Same
- `app/views/admin/music/albums/lists/show.html.erb` — Same

### View layer — Admin form partials (rename fields, improve help text, remove formatted_text, reorder)
- `app/views/admin/games/lists/_form.html.erb` — Rename fields, update help text, remove `formatted_text` textarea, reorder so `raw_content` and `simplified_content` appear first, convert `items_json` to read-only `<pre>` block
- `app/views/admin/music/songs/lists/_form.html.erb` — Same
- `app/views/admin/music/albums/lists/_form.html.erb` — Same

**Updated form field labels and help text:**

`raw_content` field:
- Label: **"Raw Content"**
- Placeholder: `"Paste HTML or plain text from the source list..."`
- Help text: `"Paste the original content from the list source — HTML or plain text. On save, this is automatically sanitized and used to populate Simplified Content below."`

`simplified_content` field:
- Label: **"Simplified Content"**
- Placeholder: `"Auto-generated from Raw Content on save..."`
- Help text: `"Auto-generated by sanitizing Raw Content (scripts, styles, images, and non-essential markup are stripped). You can manually edit this to clean up or correct the result. This is what gets sent to AI for parsing into list items."`

### View layer — Public forms
- `app/views/music/lists/_form.html.erb` — Rename `raw_html` → `raw_content` (line 275+). Existing help text is already good, no changes needed beyond the rename

### Component layer — Wizard parse step
- `app/components/admin/games/wizard/parse_step_component.rb` — Rename `raw_html` → `raw_content`
- `app/components/admin/games/wizard/parse_step_component.html.erb` — Same
- `app/components/admin/music/wizard/base_parse_step_component.rb` — Same
- `app/components/admin/music/songs/wizard/parse_step_component.html.erb` — Same
- `app/components/admin/music/albums/wizard/parse_step_component.html.erb` — Same

### Helper layer
- `app/helpers/admin/music/lists_helper.rb` — No changes needed (helper uses `items_json` param, not column name)

### Test files
- `test/models/list_test.rb` — Rename field refs in auto-simplification tests
- `test/fixtures/lists.yml` — Rename `raw_html` → `raw_content`, remove `formatted_text` values
- `test/controllers/admin/games/lists_controller_test.rb` — Rename refs, remove `formatted_text` tests
- `test/controllers/admin/music/songs/lists_controller_test.rb` — Rename refs, remove `formatted_text` tests
- `test/controllers/admin/music/albums/lists_controller_test.rb` — Rename refs, remove `formatted_text` tests
- `test/controllers/admin/games/list_wizard_controller_test.rb` — Rename `raw_html` refs
- `test/controllers/admin/music/songs/list_wizard_controller_test.rb` — Rename `raw_html` refs
- `test/controllers/music/lists_controller_test.rb` — Rename `raw_html` refs
- `test/sidekiq/games/wizard_parse_list_job_test.rb` — Rename refs
- `test/sidekiq/music/songs/wizard_parse_list_job_test.rb` — Rename refs
- `test/sidekiq/music/albums/wizard_parse_list_job_test.rb` — Rename refs
- `test/lib/services/ai/tasks/lists/music/albums_raw_parser_task_test.rb` — Rename `simplified_html` refs
- `test/lib/services/ai/tasks/lists/music/songs_raw_parser_task_test.rb` — Rename `simplified_html` refs
- `test/components/admin/music/songs/wizard/parse_step_component_test.rb` — Rename refs
- `test/components/admin/music/albums/wizard/parse_step_component_test.rb` — Rename refs

### Rake tasks
- `lib/tasks/music/songs.rake` — No direct `raw_html`/`simplified_html` refs (only `items_json`)

## Acceptance Criteria
- [x] `formatted_text` column dropped from `lists` table via migration
- [x] `raw_html` column renamed to `raw_content` via migration
- [x] `simplified_html` column renamed to `simplified_content` via migration
- [x] All model references updated (callbacks, validations, private methods)
- [x] All controller permitted params updated (`simplified_content` stays permitted, `formatted_text` and `items_json` removed)
- [x] All service/job references updated
- [x] Admin forms: `raw_content` and `simplified_content` textareas present with improved descriptive help text, `formatted_text` textarea removed
- [x] Admin forms: `raw_content` and `simplified_content` appear above `items_json` in field order
- [x] Admin forms: `items_json` displayed as read-only `<pre>` block (no longer editable)
- [x] Admin show pages: `raw_content` and `simplified_content` displayed, `formatted_text` section removed
- [x] Public forms: `raw_content` textarea present
- [x] Wizard components updated
- [x] All tests pass after rename (run `bin/rails test`)
- [x] Schema annotations regenerated automatically by annotate gem on migration
- [x] `before_save` callback still correctly auto-generates `simplified_content` from `raw_content`
- [x] SimplifierService internal variables renamed (`@raw_html` → `@raw_content`)
- [x] Error message strings updated to reference "raw content"

### Golden Examples
```text
Input: Admin saves a list with raw_content = "<ol><li>Dark Side of the Moon</li></ol>"
Output: simplified_content auto-generated via SimplifierService, stored in DB

Input: Admin views list show page
Output: raw_content and simplified_content displayed in read-only <pre> blocks

Input: Admin edits only simplified_content without changing raw_content
Output: Manual edit persists (callback only fires on raw_content change)
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture
- Respect snippet budget (≤40 lines)
- Do not duplicate authoritative code; **link to file paths**
- Use `rename_column` (not drop+add) to preserve data
- Run migrations in order: remove column first, then rename

### Required Outputs
- Updated files (paths listed in "Files To Update" above)
- Passing tests for the Acceptance Criteria
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder → verify all references are captured (grep for `raw_html`, `simplified_html`, `formatted_text`)
2) codebase-analyzer → confirm no additional references missed
3) technical-writer → update schema annotations after migration

### Test Seed / Fixtures
- Update `test/fixtures/lists.yml` — rename `raw_html` → `raw_content`, remove `formatted_text` entries

---

## Implementation Notes (living)
- Approach taken: Two separate migrations (remove column, then rename columns), followed by global find-and-replace across all code/test/view files
- Important decisions:
  - SimplifierService internal variable names also renamed (`raw_html` → `raw_content`) for consistency
  - Error message strings updated to reference "raw content" instead of "raw HTML"
  - `items_json` made read-only in admin forms — converted from editable textarea to display-only `<pre>` block, removed from `permitted_params`
  - Field order in admin forms changed: `raw_content` → `simplified_content` → `items_json` (was `items_json` first)

### Key Files Touched (paths only)
- All files listed in "Files To Update" section above
- Additionally: `app/lib/services/html/simplifier_service.rb` (internal variable rename)

### Challenges & Resolutions
- None — the spec was comprehensive and all references were captured

### Deviations From Plan
- Also renamed SimplifierService internal variable `@raw_html` → `@raw_content` (user requested)
- Also updated error message strings in ImportService and BaseWizardParseListJob (user requested)
- Made `items_json` read-only in admin forms and reordered fields (user requested post-implementation)
- Removed `items_json` from `permitted_params` (user requested)
- Updated/consolidated controller tests that were submitting `items_json` via form params

## Acceptance Results
- Date: 2026-02-25, all 3970 tests pass (0 failures, 0 errors, 0 skips)

## Future Improvements
- Consider renaming `SimplifierService` to better reflect it processes both HTML and plain text
- Consider whether the `auto_simplify` callback should handle plain text differently than HTML

## Related PRs
- #…

## Documentation Updated
- [x] Spec file updated with all implementation notes and deviations
- [ ] `documentation.md` — no updates needed (no public API changes)
- [ ] Class docs — schema annotations auto-regenerated by annotate gem
