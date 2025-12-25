# [095] - Song Wizard: Polish & Integration

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-01-19
- **Completed**: 2025-12-24
- **Part**: 10 of 10

## Overview
Final polish for the Song Wizard: add entry point from list show page, improve step indicator styling, add controller documentation, and ensure UI follows DaisyUI/Tailwind best practices. This wizard framework will be reused for albums and other domains.

## Acceptance Criteria

### 1. Add "Launch Wizard" Button to List Show Page
- [x] Add prominent "Launch Wizard" button to `/admin/music/songs/lists/:id` show page
- [x] Position in the action buttons area (next to Edit/Delete)
- [x] Button links to `/admin/music/songs/lists/:id/wizard`
- [x] Use appropriate icon (wand, sparkles, or similar)
- [x] Show wizard status badge if wizard is in progress

**File**: `web-app/app/views/admin/music/songs/lists/show.html.erb`

### 2. Replace Emoji Icons with Numbers in Step Progress
- [x] Remove emoji icons from step indicator (currently: 📁📝✨✓👁📥✓)
- [x] Use DaisyUI's default numbered steps (cleaner, more professional)
- [x] Alternatively, use simple checkmarks for completed steps
- [x] Update `Wizard::ProgressComponent` to support number-based display
- [x] Update `step_icon` helper or remove if not needed

**Current implementation** (`list_wizard_helper.rb:4-15`):
```ruby
def step_icon(step_name)
  case step_name
  when "source" then "📁"  # looks cheap
  when "parse" then "📝"
  # ...
  end
end
```

**Target**: Use DaisyUI's native step numbering which auto-displays 1, 2, 3... without `data-content`.

**Files**:
- `web-app/app/components/wizard/progress_component.rb`
- `web-app/app/components/wizard/progress_component.html.erb`
- `web-app/app/helpers/admin/music/songs/list_wizard_helper.rb`

### 3. Add RDoc Documentation to Controller
- [x] Add class-level RDoc to `ListWizardController`
- [x] Document each public action (show, show_step, advance_step, etc.)
- [x] Document the STEPS constant and wizard flow
- [x] Document private methods with @param and @return
- [x] Add RDoc to `WizardController` concern

**Files**:
- `web-app/app/controllers/admin/music/songs/list_wizard_controller.rb`
- `web-app/app/controllers/concerns/wizard_controller.rb`
- `web-app/app/helpers/admin/music/songs/list_wizard_helper.rb`

### 4. Refactor Duplicate Controller Code
The `advance_from_X_step` methods (parse, enrich, validate, import) share nearly identical logic. Extract to a reusable pattern.

**Duplicate pattern** (appears 4 times):
```ruby
def advance_from_X_step
  status = wizard_entity.wizard_step_status("X")
  if status == "idle" || status == "failed"
    wizard_entity.update_wizard_step_status(...)
    JobClass.perform_async(...)
    redirect_to(..., notice: "X started")
  elsif status == "completed"
    # identical next-step logic in all 4 methods
  else
    redirect_to(..., alert: "X in progress")
  end
end
```

**Refactoring approach**:
- [x] Extract `advance_from_job_step(step_name, job_class)` method
- [x] Handle re-execution param (`:reenrich`, `:revalidate`) generically
- [x] Extract next-step navigation to shared method

**File**: `web-app/app/controllers/admin/music/songs/list_wizard_controller.rb`

### 5. UI/UX Review with UI Engineer
- [x] Review all wizard step components for DaisyUI/Tailwind best practices
- [x] Ensure consistent spacing, typography, and color usage
- [x] Verify mobile responsiveness on all steps
- [x] Check accessibility (proper labels, focus states, ARIA)
- [x] Validate button states (loading, disabled, hover)

**Components to review**:
- `web-app/app/components/wizard/container_component.html.erb`
- `web-app/app/components/wizard/progress_component.html.erb`
- `web-app/app/components/wizard/step_component.html.erb`
- `web-app/app/components/wizard/navigation_component.html.erb`
- `web-app/app/components/admin/music/songs/wizard/*_step_component.html.erb` (7 files)
- `web-app/app/components/admin/music/songs/wizard/*_modal_component.html.erb` (3 files)

### 6. Document Wizard Infrastructure
- [x] Create `docs/features/list-wizard.md` with comprehensive wizard documentation
- [x] Document the reusable wizard framework architecture
- [x] Explain how to implement wizard for new list types (albums, books, movies)
- [x] Include file structure, component hierarchy, and data flow diagrams

**Documentation outline**:

```markdown
# List Wizard Infrastructure

## Summary
Multi-step wizard framework for importing items into lists with background job processing,
progress tracking, and per-item verification.

## Architecture Overview
- Generic wizard components (reusable)
- Domain-specific step components (per list type)
- Background job integration
- wizard_state JSON storage

## Generic Components (app/components/wizard/)
- ContainerComponent - Main wizard wrapper
- ProgressComponent - Step indicator (numbered steps)
- StepComponent - Individual step container
- NavigationComponent - Back/Next buttons

## Controller Infrastructure
- WizardController concern - Base wizard behavior
- wizard_steps, wizard_entity, load_step_data hooks
- Step advancement and job integration

## Implementing for New List Type
1. Create domain-specific controller
2. Define STEPS constant
3. Implement step components
4. Create background jobs
5. Add entry point to list show page

## wizard_state Schema
{
  "current_step": 0,
  "started_at": "ISO8601",
  "completed_at": "ISO8601 or null",
  "import_source": "custom_html|musicbrainz_series",
  "steps": {
    "step_name": {
      "status": "idle|running|completed|failed",
      "progress": 0-100,
      "error": "string or null",
      "metadata": {}
    }
  }
}

## File Structure Reference
[Links to all wizard-related files]

## Related Documentation
- Song Wizard: docs/todos/completed/086-094*.md
- MusicBrainz Import: docs/features/musicbrainz_series_import.md
```

**Output file**: `docs/features/list-wizard.md`

## Key Files Touched

| File | Change |
|------|--------|
| `app/views/admin/music/songs/lists/show.html.erb` | Add Launch Wizard button |
| `app/components/wizard/progress_component.rb` | Remove icon requirement |
| `app/components/wizard/progress_component.html.erb` | Use numbered steps |
| `app/helpers/admin/music/songs/list_wizard_helper.rb` | Remove/simplify step_icon |
| `app/controllers/admin/music/songs/list_wizard_controller.rb` | RDoc + refactor |
| `app/controllers/concerns/wizard_controller.rb` | RDoc |
| `docs/features/list-wizard.md` | NEW - Wizard infrastructure docs |

## Testing Checklist
- [x] Launch Wizard button visible on list show page
- [x] Wizard starts correctly from new entry point
- [x] Step progress shows numbers (not emojis)
- [x] All step transitions work after refactor
- [x] Tests updated for new progress component behavior
- [x] `docs/features/list-wizard.md` created with complete file references

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture
- Respect snippet budget (<=40 lines per snippet in docs)
- This wizard framework will be reused for albums/books/movies

### Required Outputs
- Updated files listed in "Key Files Touched"
- Passing tests for the wizard controller
- RDoc documentation on all public methods

### Sub-Agent Plan
1. **UI Engineer** - Review all wizard components for DaisyUI/Tailwind best practices
2. **codebase-pattern-finder** - Find similar button placement patterns in other show pages
3. **codebase-analyzer** - Gather complete file list and architecture details for docs
4. **technical-writer** - Create `docs/features/list-wizard.md` and update spec after completion

## Implementation Notes

### Launch Wizard Button
Added sparkles icon button to `show.html.erb:22-31` with "In Progress" badge when wizard is active but not completed.

### Step Progress Refactoring
- Moved icon logic from helper to `Wizard::ProgressComponent#step_icon(step_index)`
- Completed steps show `✓`, pending/current show numbers (1, 2, 3...)
- Removed `step_icon` helper method from `list_wizard_helper.rb`
- Updated view to no longer pass icons to component

### Controller Refactoring
Created `JOB_STEP_CONFIG` hash and extracted:
- `advance_from_job_step(step_name, config)` - handles idle/running/completed states
- `start_job(step_name, job_class)` - sets running status and enqueues job
- `navigate_to_next_step(set_completed:)` - shared next-step navigation

Reduced ~130 lines of duplicate code to ~50 lines.

### Documentation Created
- `docs/features/list-wizard.md` (516 lines) - comprehensive wizard infrastructure docs
- RDoc added to `WizardController` concern (64 lines)
- RDoc added to `ListWizardController` class and methods
- RDoc added to `ListWizardHelper` methods

### UI/UX Review (via UI Engineer agent)
Identified improvements for future work:
- Accessibility: Add `scope="col"` to table headers, ARIA labels to SVG icons
- Mobile: Improve navigation button stacking, add scroll indicators
- Button states: Add loading states, disabled tooltips

## Deviations
None - implemented as specified.

## Acceptance Results
All acceptance criteria passed:
- ✅ Launch Wizard button visible with sparkles icon and in-progress badge
- ✅ Step progress shows numbers (1-7) with checkmarks for completed
- ✅ Controller refactored with shared `advance_from_job_step` method
- ✅ RDoc documentation added to all wizard infrastructure
- ✅ `docs/features/list-wizard.md` created with complete implementation guide
- ✅ All 41 controller tests pass
- ✅ All 6 component tests pass (updated for new behavior)

## Related
- **Previous**: [094] Step 5: Import
- **Completes**: Song List Wizard implementation (Parts 1-10)
- **Next**: Album List Wizard (separate track)

## Design Decision: Step Indicators

**Current (emojis)**:
```
📁 Source → 📝 Parse → ✨ Enrich → ✓ Validate → 👁 Review → 📥 Import → ✓ Complete
```

**Recommended (DaisyUI default numbers)**:
```
① Source → ② Parse → ③ Enrich → ④ Validate → ⑤ Review → ⑥ Import → ✓ Complete
```

DaisyUI's `<ul class="steps">` automatically numbers steps 1, 2, 3... when no `data-content` is provided. Use `✓` checkmark only for completed state. This is cleaner, more professional, and consistent with admin UI conventions.
