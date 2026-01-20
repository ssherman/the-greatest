# Year Filter UI for Albums and Songs

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-19
- **Started**: 2026-01-19
- **Completed**: 2026-01-19
- **Developer**: Claude

## Overview
Add user-facing UI controls for the year filtering feature implemented in `docs/specs/completed/year-filtering-ranked-items.md`. This includes:
1. Navigation dropdowns with decade links for Albums/Songs
2. Horizontal filter tab bar on index pages with decade quick-links and custom range modal
3. Updated page titles and headings (remove "Top 100", use "of All Time" for unfiltered)
4. Remove ranking configuration display from public pages

**Non-goals:**
- Genre/location filtering (future spec)
- Admin UI changes
- Mobile-specific navigation (uses same responsive patterns)

## Context & Links
- Related tasks: `docs/specs/completed/year-filtering-ranked-items.md` (backend complete)
- Source files (authoritative):
  - `app/views/layouts/music/application.html.erb`
  - `app/views/music/albums/ranked_items/index.html.erb`
  - `app/views/music/songs/ranked_items/index.html.erb`
  - `app/helpers/music/albums/ranked_items_helper.rb`
  - `app/helpers/music/songs/ranked_items_helper.rb`
- External docs: DaisyUI dropdown, tabs, modal components

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes required.

### Endpoints
No new endpoints. Uses existing routes:
| Verb | Path | Purpose | Example |
|---|---|---|---|
| GET | /albums | Albums (all time) | /albums |
| GET | /albums/:year | Decade, range, or single year | /albums/1990s, /albums/1980-2000, /albums/1994 |
| GET | /albums/since/:year | Albums from year onward | /albums/since/1980 |
| GET | /albums/through/:year | Albums up to year | /albums/through/1980 |
| GET | /songs | Songs (all time) | /songs |
| GET | /songs/:year | Decade, range, or single year | /songs/1990s, /songs/1980-2000, /songs/1994 |
| GET | /songs/since/:year | Songs from year onward | /songs/since/1980 |
| GET | /songs/through/:year | Songs up to year | /songs/through/1980 |

### Component Schemas

**Navigation Dropdown Item:**
```json
{
  "label": "string",
  "path": "string",
  "description": "string (optional, for accessibility)"
}
```

**Example Navigation Items (Albums):**
```json
[
  {"label": "All Time", "path": "/albums"},
  {"label": "1960s", "path": "/albums/1960s"},
  {"label": "1970s", "path": "/albums/1970s"},
  {"label": "1980s", "path": "/albums/1980s"},
  {"label": "1990s", "path": "/albums/1990s"},
  {"label": "2000s", "path": "/albums/2000s"},
  {"label": "2010s", "path": "/albums/2010s"},
  {"label": "2020s", "path": "/albums/2020s"}
]
```

**Filter Tab Configuration:**
```json
{
  "decades": ["1960s", "1970s", "1980s", "1990s", "2000s", "2010s", "2020s"],
  "all_time_label": "All Time",
  "custom_label": "Custom"
}
```

### Behaviors (pre/postconditions)

**Navigation Dropdown:**
- Preconditions: User hovers/focuses on Albums or Songs nav item
- Postconditions: Dropdown appears with decade links
- Edge cases: On mobile, hamburger menu shows expanded list (no hover)

**Filter Tab Bar:**
- Preconditions: User is on /albums or /songs index page
- Postconditions: Current filter highlighted, clicking navigates to filtered page
- Edge cases:
  - Year range filter (e.g., `/albums/1980-2000`) shows "Custom" as active
  - Single year filter (e.g., `/albums/1994`) shows "Custom" as active
  - Since/through filters show "Custom" as active

**Custom Range Modal:**
- Preconditions: User clicks "Custom" tab
- Postconditions: Modal opens with two year inputs and Apply button
- Validation:
  - At least one field required (From or To)
  - If both filled: Start year <= End year
  - Years must be 4 digits (1900-2099 reasonable range)
- URL routing logic (Stimulus controller):
  - Neither field → Apply disabled
  - Only "From" filled → `/albums/since/{from_year}`
  - Only "To" filled → `/albums/through/{to_year}`
  - Both filled, same year → `/albums/{year}` (single)
  - Both filled, different → `/albums/{from_year}-{to_year}` (range)
- On Cancel: Modal closes, no navigation

### Non-Functionals
- **Performance**: No additional database queries (filter logic already exists)
- **Accessibility**:
  - Dropdown keyboard navigable (Tab, Enter, Escape)
  - Modal focus trap and Escape to close
  - ARIA labels on all interactive elements
- **Responsiveness**:
  - Desktop: Horizontal nav dropdown, full tab bar
  - Mobile: Hamburger menu shows full decade list, tab bar scrolls horizontally

## Acceptance Criteria

### Navigation Updates
- [x] Albums nav item is a dropdown with: All Time, 1960s, 1970s, 1980s, 1990s, 2000s, 2010s, 2020s
- [x] Songs nav item is a dropdown with same decade options
- [x] Mobile hamburger menu shows Albums/Songs as expandable sections
- [x] Dropdown uses DaisyUI dropdown pattern (focus-based, no JS required)
- [x] Keyboard navigation works (Tab through items, Enter to select, Escape to close)

### Filter Tab Bar
- [x] Tab bar appears below page heading on /albums and /songs
- [x] Tabs: All Time | 1960s | 1970s | 1980s | 1990s | 2000s | 2010s | 2020s | Custom
- [x] Current filter tab has active/selected styling
- [x] Clicking a decade tab navigates to `/albums/{decade}` or `/songs/{decade}`
- [x] "Custom" tab opens modal instead of navigating
- [x] Tab bar is horizontally scrollable on mobile (overflow-x-auto)

### Custom Range Modal
- [x] Modal has two number inputs: "From Year" and "To Year"
- [x] Inputs have placeholder text showing format (e.g., "1980")
- [x] Input labels clarify optional nature: "From Year (optional)" / "To Year (optional)"
- [x] Apply button is disabled until at least one field has a valid year
- [x] Stimulus controller builds correct URL based on inputs:
  - [x] Only From filled → navigates to `/albums/since/{year}` or `/songs/since/{year}`
  - [x] Only To filled → navigates to `/albums/through/{year}` or `/songs/through/{year}`
  - [x] Both filled, same year → navigates to single year URL (e.g., `/albums/1994`)
  - [x] Both filled, different years → navigates to range URL (e.g., `/albums/1980-2000`)
- [x] Validation error shown if both filled and From > To
- [x] Cancel button closes modal without navigation
- [x] Modal closes on backdrop click
- [x] Focus moves to first input when modal opens (native dialog behavior)
- [x] Escape key closes modal

### Page Title/Heading Updates
- [x] `/albums` shows heading "Greatest Albums of All Time" (not "Top Albums")
- [x] `/songs` shows heading "Greatest Songs of All Time" (not "Top Songs")
- [x] Page `<title>` updated: "Greatest Albums of All Time | The Greatest Music"
- [x] Page `<title>` updated: "Greatest Songs of All Time | The Greatest Music"
- [x] Meta descriptions updated to match new heading style
- [x] Filtered pages keep existing heading format (e.g., "Greatest Albums of the 1990s")

### Ranking Configuration Removal
- [x] Remove ranking configuration name/description display from /albums page
- [x] Remove ranking configuration name/description display from /songs page
- [x] No visible reference to ranking configuration on public pages

### Golden Examples

**Navigation Dropdown (Desktop):**
```text
Before: Albums (simple link)
After:  Albums ▼
          ├─ All Time
          ├─ 1960s
          ├─ 1970s
          ├─ 1980s
          ├─ 1990s
          ├─ 2000s
          ├─ 2010s
          └─ 2020s
```

**Filter Tab Bar:**
```text
┌──────────┬───────┬───────┬───────┬───────┬───────┬───────┬───────┬────────┐
│ All Time │ 1960s │ 1970s │ 1980s │ 1990s │ 2000s │ 2010s │ 2020s │ Custom │
└──────────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┴────────┘
                                    ▲ active (underlined/highlighted)
```

**Custom Modal:**
```text
┌─────────────────────────────────────┐
│  Custom Year Range              [X] │
├─────────────────────────────────────┤
│  From Year         To Year          │
│  (optional)        (optional)       │
│  ┌──────────┐     ┌──────────┐      │
│  │ 1980     │     │ 2000     │      │
│  └──────────┘     └──────────┘      │
│                                     │
│            [Cancel]  [Apply]        │
└─────────────────────────────────────┘
```

**Custom Modal URL Routing Examples:**
```text
From: 1980    To: 2000   → /albums/1980-2000  (range)
From: 1994    To: 1994   → /albums/1994       (single year)
From: 1980    To: (empty)→ /albums/since/1980 (since)
From: (empty) To: 1980   → /albums/through/1980 (through)
From: (empty) To: (empty)→ [Apply disabled]
```

**Page Heading (Unfiltered):**
```text
Before: Top Albums
After:  Greatest Albums of All Time
```

### Optional Reference Snippet (URL building logic, non-authoritative)
```javascript
// reference only - Stimulus controller URL building logic
buildUrl() {
  const from = this.fromTarget.value.trim()
  const to = this.toTarget.value.trim()
  const base = this.basePathValue // "/albums" or "/songs"

  if (!from && !to) return null // disabled
  if (from && !to) return `${base}/since/${from}`
  if (!from && to) return `${base}/through/${to}`
  if (from === to) return `${base}/${from}`
  return `${base}/${from}-${to}`
}
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.
- Use DaisyUI components (dropdown, tabs, modal) per existing patterns.
- Use Stimulus controllers only where pure CSS won't work (modal form validation).

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → DaisyUI dropdown, tabs, modal patterns
2) codebase-analyzer → verify navigation structure, helper integration
3) UI Engineer → component design review
4) technical-writer → update docs and cross-refs after implementation

### Test Seed / Fixtures
- Use existing album/song fixtures
- System tests for navigation dropdown interaction
- System tests for filter tab navigation
- System tests for custom modal flow

### Implementation Approach

**Phase 1: Navigation Dropdowns**
1. Create shared partial for decade dropdown items
2. Update `app/views/layouts/music/application.html.erb` navbar
3. Convert Albums/Songs links to DaisyUI dropdowns
4. Update mobile hamburger menu with expanded sections

**Phase 2: Filter Tab Bar**
1. Create `Music::FilterTabsComponent` ViewComponent
2. Add to albums and songs index views
3. Implement active state logic based on `@year_filter`
4. Add horizontal scroll for mobile

**Phase 3: Custom Range Modal**
1. Create `year_range_modal_controller.js` Stimulus controller with:
   - `basePath` value (e.g., "/albums" or "/songs")
   - Input change handlers to enable/disable Apply button
   - URL building logic:
     - Neither → disabled
     - Only from → `{basePath}/since/{from}`
     - Only to → `{basePath}/through/{to}`
     - Both same → `{basePath}/{year}`
     - Both different → `{basePath}/{from}-{to}`
   - Validation: if both filled, from <= to
2. Add modal HTML to index views (or shared partial)
3. Wire up Stimulus controller with data attributes

**Phase 4: Page Updates**
1. Update helper methods for new heading format
2. Remove ranking configuration display from views
3. Update meta descriptions

---

## Implementation Notes (living)

### Approach
- Updated navbar in `app/views/layouts/music/application.html.erb` with DaisyUI `<details>` dropdowns for Albums/Songs
- Created `Music::FilterTabsComponent` ViewComponent with horizontal tab bar and modal
- Created `year_range_modal_controller.js` Stimulus controller for URL building logic
- Updated helper methods to use "Greatest Albums/Songs of All Time" instead of "Top Albums/Songs"
- Removed ranking configuration display from index views

### Important Decisions
- Used DaisyUI `<details>` pattern for dropdowns (no JS required, keyboard accessible)
- Modal uses Stimulus controller for URL building instead of form submission
- Filter tabs component is reusable for both albums and songs with `item_type` and `base_path` params

### Key Files Touched (paths only)
- `app/views/layouts/music/application.html.erb`
- `app/views/music/albums/ranked_items/index.html.erb`
- `app/views/music/songs/ranked_items/index.html.erb`
- `app/helpers/music/albums/ranked_items_helper.rb`
- `app/helpers/music/songs/ranked_items_helper.rb`
- `app/helpers/music/ranked_items_helper.rb`
- `app/components/music/filter_tabs_component.rb` (new)
- `app/components/music/filter_tabs_component.html.erb` (new)
- `app/javascript/controllers/year_range_modal_controller.js` (new)
- `test/components/music/filter_tabs_component_test.rb` (new)
- `test/system/music/albums/year_filter_test.rb` (new)
- `test/system/music/songs/year_filter_test.rb` (new)

### Challenges & Resolutions
_To be filled during implementation_

### Deviations From Plan
_To be filled during implementation_

## Acceptance Results
- Date: 2026-01-19
- Verifier: Claude
- All 3147 tests pass
- Manual testing confirmed UI works correctly on desktop and mobile

## Future Improvements
- Genre filter integration in tab bar/modal
- Location filter integration
- Combined year + genre filtering
- Breadcrumb showing current filter
- Pre-populate modal inputs when editing existing custom filter

## Related PRs
- Pending

## Documentation Updated
- [x] Class docs for `Music::FilterTabsComponent` - see `docs/components/music/filter_tabs_component.md`
- [x] Class docs for `year_range_modal_controller.js` - see `docs/javascript/controllers/year_range_modal_controller.md`
