# 108 - Public List Submission Form

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-05
- **Started**: 2026-01-05
- **Completed**: 2026-01-05
- **Developer**: Claude

## Overview
Create a public-facing form that allows anonymous users to submit music lists (albums or songs) for review. The form should be accessible from the `/music/lists` index page and collect all relevant list metadata with user-friendly explanations for each field. If the user is logged in, the `submitted_by_id` is set; otherwise, the list is created without user association.

**Scope**:
- New `/music/lists/new` action on public `Music::ListsController`
- Form to select list type (albums vs songs) and enter list metadata
- Subset of flags with explanations
- `raw_html` field relabeled as "Albums or Songs" for free-text item entry
- User-friendly design with field explanations

**Non-Goals**:
- List item parsing/importing (handled separately by admin wizards)
- Admin approval workflow changes
- Email notifications on submission

## Context & Links
- Related page: `app/views/music/lists/index.html.erb`
- Existing public controller: `app/controllers/music/lists_controller.rb`
- List model: `app/models/list.rb`
- Album list subclass: `app/models/music/albums/list.rb`
- Song list subclass: `app/models/music/songs/list.rb`
- Admin list form patterns: `app/views/admin/music/albums/lists/_form.html.erb`
- DaisyUI docs: https://daisyui.com/llms.txt

## Interfaces & Contracts

### Domain Model (diffs only)
No schema changes required. The existing `List` model already has:
- `submitted_by_id` (references User, nullable)
- `status` (enum, defaults to `unapproved`)
- All fields needed for the submission form

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /music/lists/new | Display submission form | - | public |
| POST | /music/lists | Create new list submission | list_type, list attributes | public |

> Route additions to `config/routes.rb` in the `music` namespace.

### Request Body Schema (POST /music/lists)
```json
{
  "type": "object",
  "required": ["list_type", "list"],
  "properties": {
    "list_type": {
      "type": "string",
      "enum": ["albums", "songs"],
      "description": "Determines List subclass to create"
    },
    "list": {
      "type": "object",
      "required": ["name"],
      "properties": {
        "name": { "type": "string", "maxLength": 255 },
        "description": { "type": "string" },
        "source": { "type": "string", "maxLength": 255 },
        "url": { "type": "string", "format": "uri" },
        "year_published": { "type": "integer", "minimum": 1900 },
        "number_of_voters": { "type": "integer", "minimum": 1 },
        "num_years_covered": { "type": "integer", "minimum": 1 },
        "location_specific": { "type": "boolean" },
        "category_specific": { "type": "boolean" },
        "yearly_award": { "type": "boolean" },
        "voter_count_estimated": { "type": "boolean" },
        "voter_names_unknown": { "type": "boolean" },
        "voter_count_unknown": { "type": "boolean" },
        "raw_html": { "type": "string", "description": "Free-text list of albums/songs" }
      }
    }
  }
}
```

### Behaviors (pre/postconditions)

**Preconditions**:
- None (public endpoint)

**Postconditions**:
- New `Music::Albums::List` or `Music::Songs::List` record created
- `status` set to `unapproved` (default)
- `submitted_by_id` set to `current_user.id` if logged in, `nil` otherwise
- User redirected to lists index with success flash

**Edge Cases & Failure Modes**:
- Invalid list_type → render form with error
- Missing required `name` → render form with validation errors
- Invalid URL format → render form with validation error
- Very long raw_html content → accept (no length limit)

### Non-Functionals
- **Performance**: Form submission < 500ms
- **Security**: CSRF protection via Rails defaults, no admin-only fields exposed
- **Responsiveness**: Form usable on mobile devices
- **Accessibility**: All fields labeled, form errors announced

## Acceptance Criteria
- [x] "Submit a List" link appears on `/music/lists` index page
- [x] GET `/music/lists/new` renders submission form
- [x] Form includes radio/select to choose Album List vs Song List
- [x] Form includes all basic fields: name (required), description, source, url, year_published, number_of_voters, num_years_covered
- [x] Form includes subset of flags with explanations:
  - [x] Location Specific - with explanation
  - [x] Category Specific - with explanation
  - [x] Yearly Award - with explanation
  - [x] Voter Count Estimated - with explanation
  - [x] Voter Names Unknown - with explanation
  - [x] Voter Count Unknown - with explanation
- [x] Form includes "Albums or Songs" textarea (raw_html field) with explanation
- [x] Each field has user-friendly help text explaining its purpose
- [x] Successful submission creates list with `status: unapproved`
- [x] If user logged in, `submitted_by_id` is set to current user
- [x] If user not logged in, `submitted_by_id` is nil
- [x] After successful submission, redirect to `/music/lists` with success message
- [x] Validation errors display inline with DaisyUI styling
- [x] Form is responsive (mobile-friendly)

### Golden Examples

**Example 1: Anonymous Album List Submission**
```text
Input:
  list_type: "albums"
  list[name]: "Rolling Stone's 500 Greatest Albums of All Time (2020)"
  list[source]: "Rolling Stone"
  list[url]: "https://www.rollingstone.com/music/music-lists/best-albums-of-all-time-1062063/"
  list[year_published]: 2020
  list[number_of_voters]: 300
  list[description]: "Updated version of the classic list with new selections"
  list[category_specific]: false
  list[location_specific]: false
  list[raw_html]: "1. Marvin Gaye - What's Going On\n2. The Beach Boys - Pet Sounds\n..."
  User: not logged in

Output:
  Music::Albums::List created with:
    - name: "Rolling Stone's 500 Greatest Albums of All Time (2020)"
    - status: "unapproved"
    - submitted_by_id: nil
  Redirect to /music/lists with flash: "Thank you for your submission! Your list will be reviewed shortly."
```

**Example 2: Logged-in Song List Submission**
```text
Input:
  list_type: "songs"
  list[name]: "Triple J Hottest 100 of 2024"
  list[source]: "Triple J"
  list[year_published]: 2024
  list[yearly_award]: true
  list[location_specific]: true
  list[voter_count_estimated]: true
  list[raw_html]: "1. Glass Animals - Heat Waves\n2. ..."
  User: logged in as user#42

Output:
  Music::Songs::List created with:
    - status: "unapproved"
    - submitted_by_id: 42
    - yearly_award: true
    - location_specific: true
  Redirect with success flash
```

## UI/UX Design

### Form Structure

The form should be organized into clear sections with cards (matching admin patterns):

```
┌─────────────────────────────────────────────────────────────────┐
│  Submit a Music List                                             │
│  Help us expand our collection of greatest music lists           │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │ List Type                                                    │ │
│  │ ○ Album List  ○ Song List                                   │ │
│  │ [Explanation of the difference]                              │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │ Basic Information                                            │ │
│  │ Name *: [________________________]                           │ │
│  │ Description: [textarea]                                      │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │ Source Information                                           │ │
│  │ Source: [________________________]                           │ │
│  │ URL: [________________________]                              │ │
│  │ Year Published: [____]                                       │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │ Voter Information                                            │ │
│  │ Number of Voters: [____]                                     │ │
│  │ Years Covered: [____]                                        │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │ List Characteristics                                         │ │
│  │ ☐ Location Specific                                         │ │
│  │   (List focuses on a specific country or region)            │ │
│  │ ☐ Category Specific                                         │ │
│  │   (List focuses on a specific genre or category)            │ │
│  │ ☐ Yearly Award                                              │ │
│  │   (List is an annual award that recurs each year)           │ │
│  │ ☐ Voter Count Estimated                                     │ │
│  │   (The number of voters is an estimate, not exact)          │ │
│  │ ☐ Voter Names Unknown                                       │ │
│  │   (The identities of voters are not publicly known)         │ │
│  │ ☐ Voter Count Unknown                                       │ │
│  │   (The total number of voters is unknown)                   │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │ Albums or Songs                                              │ │
│  │ [Large textarea]                                             │ │
│  │ Paste or type the list items, one per line. Include artist  │ │
│  │ names and rankings if available. Example:                    │ │
│  │ 1. Artist Name - Album/Song Title                           │ │
│  │ 2. Another Artist - Another Title                           │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  [Cancel]  [Submit List]                                         │
└─────────────────────────────────────────────────────────────────┘
```

### Field Explanations

| Field | Label | Help Text |
|-------|-------|-----------|
| list_type | List Type | Choose whether this list ranks albums or songs. |
| name | List Name | The official name of the list (e.g., "Rolling Stone's 500 Greatest Albums"). Required. |
| description | Description | A brief overview of this list - what makes it notable, how it was compiled, etc. |
| source | Source/Publication | The publication, website, or organization that created this list. |
| url | Original URL | Link to the original list if available online. |
| year_published | Year Published | The year this list was published or last updated. |
| number_of_voters | Number of Voters | How many critics, readers, or experts voted on this list? |
| num_years_covered | Years Covered | How many years of releases does this list consider? (e.g., "all time" might be 100+) |
| location_specific | Location Specific | Check if this list focuses on music from a specific country or region (e.g., "Best British Albums"). |
| category_specific | Category Specific | Check if this list focuses on a specific genre or style (e.g., "Best Jazz Albums"). |
| yearly_award | Yearly Award | Check if this is an annual award that recurs each year (e.g., "Grammy Album of the Year"). |
| voter_count_estimated | Voter Count Estimated | Check if the number of voters above is an estimate rather than an exact count. |
| voter_names_unknown | Voter Names Unknown | Check if the voters' identities are anonymous or not publicly known. |
| voter_count_unknown | Voter Count Unknown | Check if the total number of voters is completely unknown (leave "Number of Voters" blank). |
| raw_html | Albums or Songs | Paste or type the list items here, one per line. Include rankings, artist names, and titles. We'll process this into individual entries. |

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Use DaisyUI components and existing form styling patterns.
- Keep controller logic minimal; the form simply creates a List record.
- Respect snippet budget (≤40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) **codebase-pattern-finder** → find existing form patterns in public music views
2) **UI Engineer** → design and implement the form with proper DaisyUI styling
3) **codebase-analyzer** → verify controller routing and List model integration
4) **technical-writer** → update docs if needed

### Test Seed / Fixtures
- Use existing `users(:admin)` fixture for logged-in tests
- Create lists through the form in integration tests

---

## Implementation Notes (living)
- Approach taken: Extended existing `Music::ListsController` with `new` and `create` actions using STI to create either `Music::Albums::List` or `Music::Songs::List` based on user selection
- Important decisions:
  - Used radio buttons for list type selection with explanatory text
  - Form uses `form_with url:` pattern since we create different model types based on `list_type` param
  - Added flash message support to music layout (was missing)
  - Used DaisyUI cards with checkboxes that have explanatory help text for each flag
  - Routes use `scope as: "music"` to prefix all route helpers (`music_lists_path`, `new_music_list_path`) to avoid conflicts when games/movies domains are added

### Key Files Touched (paths only)
- `web-app/config/routes.rb` (added lists resource with `scope as: "music"`)
- `web-app/app/controllers/music/lists_controller.rb` (added `new`, `create` actions, `list_params`, `list_class_from_type`)
- `web-app/app/views/music/lists/new.html.erb` (new form view)
- `web-app/app/views/music/lists/_form.html.erb` (form partial with DaisyUI styling)
- `web-app/app/views/music/lists/index.html.erb` (added "Submit a List" button)
- `web-app/app/views/layouts/music/application.html.erb` (added flash message rendering, updated route helpers)
- `web-app/test/controllers/music/lists_controller_test.rb` (12 tests covering all acceptance criteria)

### Challenges & Resolutions
- Flash messages weren't rendering: Added flash message support to the music application layout
- Route naming conflicts: Used `scope as: "music"` pattern to prefix route helpers, preventing conflicts when other domains add similar resources

### Deviations From Plan
- Did not create a separate integration test file (`test/integration/public_list_submission_test.rb`) - all tests are in the controller test file which covers the same functionality through integration testing

## Acceptance Results
- Date: 2026-01-05
- Verifier: Claude
- All 12 controller tests passing
- Form renders correctly with DaisyUI styling
- List submission works for both album and song types
- Flash messages display on successful submission

## Future Improvements
- Email notification to admin when new list submitted
- CAPTCHA or rate limiting for spam prevention
- Preview of parsed items before submission
- Allow editing of submitted lists (if logged in and own submission)

## Related PRs
- #…

## Documentation Updated
- [x] Controller docs: `docs/controllers/music/lists_controller.md`
