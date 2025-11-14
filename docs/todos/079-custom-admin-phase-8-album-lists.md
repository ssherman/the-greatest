# 079 - Custom Admin Interface - Phase 8: Album Lists

## Status
- **Status**: 📋 Planning
- **Priority**: High
- **Created**: 2025-11-13
- **Started**: TBD
- **Completed**: TBD
- **Developer**: Claude Code (AI Agent)

## Overview
Implement custom admin CRUD interface for Music::Albums::List following patterns established in Phase 1 (Artists) and Phase 2 (Albums). This phase focuses on **basic CRUD only** - no actions yet. Replace Avo album list resource with custom Rails admin built on ViewComponents + Hotwire (Turbo + Stimulus).

## Context
- **Previous Phases Complete**: Artists (Phase 1), Albums (Phase 2), Album Artists (Phase 3), Songs (Phase 4), Song Artists (Phase 5), Ranking Configurations (Phase 6-7)
- **Proven Architecture**: ViewComponents, Hotwire, DaisyUI, OpenSearch patterns established
- **Model**: Music::Albums::List (STI model inheriting from List)
- **Scope**: Basic CRUD only - defer all Avo actions to future phase
- **Key Difference**: NO actions yet (different from previous phases which included actions)

## Contracts

### 1. Routes & Route Ordering

**CRITICAL**: Lists routes MUST come BEFORE album/song resources to prevent slug conflicts.

```ruby
# config/routes.rb

# Inside Music domain constraint
constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
  namespace :admin, module: "admin/music" do
    # ... existing routes ...

    # Lists routes - MUST come BEFORE resources :albums to prevent slug conflicts
    namespace :albums do
      resources :lists
    end

    # Future: Songs lists (Phase 9+)
    # namespace :songs do
    #   resources :lists
    # end

    # Main resources (albums, songs) come AFTER lists
    resources :albums do
      # ... existing nested routes ...
    end

    resources :songs do
      # ... existing nested routes ...
    end
  end
end
```

**Route Table:**

| Verb | Path | Purpose | Controller#Action | Auth |
|------|------|---------|-------------------|------|
| GET | /admin/albums/lists | Index with sort | Admin::Music::Albums::ListsController#index | admin/editor |
| GET | /admin/albums/lists/:id | Show details | Admin::Music::Albums::ListsController#show | admin/editor |
| GET | /admin/albums/lists/new | New form | Admin::Music::Albums::ListsController#new | admin/editor |
| POST | /admin/albums/lists | Create | Admin::Music::Albums::ListsController#create | admin/editor |
| GET | /admin/albums/lists/:id/edit | Edit form | Admin::Music::Albums::ListsController#edit | admin/editor |
| PATCH/PUT | /admin/albums/lists/:id | Update | Admin::Music::Albums::ListsController#update | admin/editor |
| DELETE | /admin/albums/lists/:id | Destroy | Admin::Music::Albums::ListsController#destroy | admin/editor |

**Generated path helpers:**
- `admin_albums_lists_path` → `/admin/albums/lists`
- `admin_albums_list_path(@list)` → `/admin/albums/lists/:id`
- `new_admin_albums_list_path` → `/admin/albums/lists/new`
- `edit_admin_albums_list_path(@list)` → `/admin/albums/lists/:id/edit`

**Why this ordering?**
If lists routes come AFTER `resources :albums`, Rails tries to match `/admin/albums/lists` as `/admin/albums/:id` where `id="lists"`, looking for an album with slug "lists". By placing lists routes first, Rails matches the more specific route before falling through to the generic `:id` matcher.

**Reference**: `/home/shane/dev/the-greatest/web-app/config/routes.rb:40-121` (ranking configurations use same pattern)

---

### 2. Controller Architecture

#### Base Controller Pattern

**File**: `app/controllers/admin/music/lists_controller.rb`

**Purpose**: Shared base controller containing all CRUD logic for lists (Albums and Songs).

**Responsibilities:**
- Standard CRUD (index, show, new, create, edit, update, destroy)
- No search endpoint (lists don't use autocomplete)
- No action execution endpoints (deferred to Phase 9)
- Eager loading associations to prevent N+1 queries
- Sortable column whitelist
- Strong parameters

**Protected Methods to Override:**
- `list_class` → Returns `Music::Albums::List` or `Music::Songs::List`
- `lists_path` → Returns path helper for index
- `list_path(list)` → Returns path helper for show
- `new_list_path` → Returns path helper for new
- `edit_list_path(list)` → Returns path helper for edit

**Strong Parameters:**
```ruby
def list_params
  params.require(:music_albums_list).permit(
    :name,
    :description,
    :source,
    :url,
    :year_published,
    :number_of_voters,
    :estimated_quality,
    :status,
    :high_quality_source,
    :category_specific,
    :location_specific,
    :yearly_award,
    :voter_count_estimated,
    :voter_count_unknown,
    :voter_names_unknown,
    :num_years_covered,
    :musicbrainz_series_id
  )
end
```

**Sortable Columns:**
```ruby
def sortable_column(column)
  allowed_columns = {
    "id" => "lists.id",
    "name" => "lists.name",
    "year_published" => "lists.year_published",
    "created_at" => "lists.created_at"
  }

  allowed_columns.fetch(column.to_s, "lists.name")
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/ranking_configurations_controller.rb`

---

#### Albums Lists Controller

**File**: `app/controllers/admin/music/albums/lists_controller.rb`

**Purpose**: Album-specific lists controller (inherits all logic from base).

```ruby
module Admin
  module Music
    module Albums
      class ListsController < Admin::Music::ListsController
        protected

        def list_class
          ::Music::Albums::List
        end

        def lists_path
          admin_albums_lists_path
        end

        def list_path(list)
          admin_albums_list_path(list)
        end

        def new_list_path
          new_admin_albums_list_path
        end

        def edit_list_path(list)
          edit_admin_albums_list_path(list)
        end
      end
    end
  end
end
```

**Note**: This is the ONLY controller needed for Phase 8. Songs lists controller (`Admin::Music::Songs::ListsController`) will be created in a future phase.

**Reference**: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/albums/ranking_configurations_controller.rb`

---

### 3. Index Page Contract

**Display Columns:**
- ID (sortable, monospace font)
- Name (sortable, link to show page, primary)
- Status (badge with color coding)
- Source (link to URL in new window if present, truncated if long)
- Year Published (sortable)
- Albums Count (badge, count of list_items)
- Created At (sortable, formatted date)
- Actions (View, Edit, Delete buttons)

**Features:**
- ✅ Pagination (Pagy, 25 items per page)
- ✅ Sort by: id, name, year_published, created_at
- ✅ Row selection checkboxes (UI only, no bulk actions yet)
- ❌ NO search (lists don't use OpenSearch)
- ❌ NO bulk actions dropdown (deferred to future phase)

**Source Column Display:**
- If `list.url.present?`: Show `list.source` as link to `list.url` with `target: "_blank"` and `rel: "noopener"`
- If `list.url.blank?`: Show `list.source` as plain text
- If `list.source.blank?`: Show "-" placeholder
- Truncate source text to ~30 chars if longer (use tooltip or ellipsis)

Example:
```erb
<% if list.url.present? %>
  <%= link_to list.source.presence || list.url, list.url,
      target: "_blank",
      rel: "noopener",
      class: "link link-primary",
      title: list.source %>
<% else %>
  <%= list.source.presence || content_tag(:span, "-", class: "text-base-content/30") %>
<% end %>
```

**Eager Loading:**
```ruby
@lists = Music::Albums::List
  .includes(:submitted_by)
  .left_joins(:list_items)
  .select("music_albums_lists.*, COUNT(DISTINCT list_items.id) as albums_count")
  .group("music_albums_lists.id")
```

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/artists/index.html.erb`

---

### 4. Show Page Contract

**Section Layout:**

1. **Basic Information Card**
   - Name, Status, Year Published
   - Source, URL (as clickable link)
   - Submitted By (with link if present)
   - Created/Updated timestamps

2. **Metadata Card**
   - Number of Voters
   - Estimated Quality
   - Number of Years Covered
   - MusicBrainz Series ID (if present)

3. **Flags Card**
   - High Quality Source
   - Category Specific
   - Location Specific
   - Yearly Award
   - Voter Count Estimated/Unknown
   - Voter Names Unknown

4. **Description Card** (if present)
   - Full description text

5. **Albums Card**
   - Count badge
   - Table of list_items:
     - Position
     - Album title (with link to album admin)
     - Artists
     - Year
     - Verified status
   - Ordered by position
   - Paginated if > 25 items
   - Message if no albums yet

6. **Raw Data Cards** (displayed LAST)
   - **items_json**: Pretty-printed JSON in `<pre>` tag with syntax highlighting
   - **raw_html**: Text display (truncated if > 1000 chars)
   - **simplified_html**: Text display (truncated if > 1000 chars)
   - **formatted_text**: Text display (truncated if > 1000 chars)

**Key Requirement**: items_json, raw_html, simplified_html, formatted_text must be displayed LAST as they are very long

**Eager Loading:**
```ruby
@list = Music::Albums::List
  .includes(
    :submitted_by,
    :penalties,
    list_items: {
      listable: [:artists, :categories, :primary_image]
    }
  )
  .find(params[:id])
```

**items_json Display Example:**
```erb
<% if @list.items_json.present? %>
  <div class="card bg-base-100 shadow-xl">
    <div class="card-body">
      <h2 class="card-title">Items JSON</h2>
      <pre class="bg-base-200 p-4 rounded-lg overflow-x-auto"><code class="language-json"><%= JSON.pretty_generate(@list.items_json) %></code></pre>
    </div>
  </div>
<% end %>
```

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/artists/show.html.erb`

---

### 5. Form Contract

**Fields (grouped in cards):**

**Basic Information Card:**
- Name (text, required, autofocus)
- Description (textarea, optional)
- Status (select dropdown with enum values)

**Source Information Card:**
- Source (text, optional)
- URL (url field, optional, validated format)
- Year Published (number, optional)
- MusicBrainz Series ID (text, optional)

**Quality Metrics Card:**
- Number of Voters (number, optional)
- Estimated Quality (number, optional)
- Number of Years Covered (number, optional, > 0)

**Flags Card:**
- High Quality Source (checkbox)
- Category Specific (checkbox)
- Location Specific (checkbox)
- Yearly Award (checkbox)
- Voter Count Estimated (checkbox)
- Voter Count Unknown (checkbox)
- Voter Names Unknown (checkbox)

**Note Box** (info alert):
"Albums can be managed after creating the list using Items JSON import (future feature)"

**Form Actions:**
- Cancel button (links to show if editing, index if creating)
- Submit button (changes text: "Create Album List" vs "Update Album List")

**Validation Errors:**
- Display at top of form in alert-error box
- Inline field errors with red border and error text

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/artists/_form.html.erb`

---

### 6. Empty States

**Index empty state:**
```
Icon: List icon
Title: "No album lists found"
Message: "Get started by creating your first album list."
Action: "New Album List" button
```

**Show page - no albums:**
```
Message: "No albums in this list yet. Albums can be imported using Items JSON (future feature)."
```

---

### 7. Navigation Integration

**Sidebar Navigation** (`app/views/admin/shared/_sidebar.html.erb`):

Add under Music section:
```erb
<li><%= link_to "Lists: Albums", admin_albums_lists_path %></li>
```

Position: After "Songs", before "Categories"

**Future Addition** (Phase 9+):
```erb
<li><%= link_to "Lists: Albums", admin_albums_lists_path %></li>
<li><%= link_to "Lists: Songs", admin_songs_lists_path %></li>
```

**Naming Rationale**: Using "Lists: [Type]" format groups all list admin pages together visually and makes the pattern clear for future expansion.

---

## Non-Functional Requirements

### Performance
- **N+1 Prevention**: Eager load all associations used in views
- **Index Query**: SQL aggregate for albums_count
- **Pagination**: 25 items per page via Pagy
- **Show Page**: Use `with_albums_for_display` scope when available

### Security
- **Authentication**: admin or editor role required (via `Admin::Music::BaseController`)
- **Strong Parameters**: Whitelist only permitted fields
- **URL Validation**: Rails URL format validator on `url` field

### Responsiveness
- Mobile: Stack header elements vertically
- Tablet: 2-column grid in forms
- Desktop: Full layout with proper spacing

---

## Acceptance Criteria

### Basic CRUD
- [ ] GET /admin/albums/lists shows paginated list with sort links
- [ ] GET /admin/albums/lists/:id shows all list details and albums
- [ ] GET /admin/albums/lists/new shows form for creating list
- [ ] POST /admin/albums/lists creates new list with valid data
- [ ] POST /admin/albums/lists shows validation errors for invalid data
- [ ] GET /admin/albums/lists/:id/edit shows form for editing list
- [ ] PATCH /admin/albums/lists/:id updates list with valid data
- [ ] PATCH /admin/albums/lists/:id shows validation errors for invalid data
- [ ] DELETE /admin/albums/lists/:id destroys list and redirects to index

### Display Requirements
- [ ] Index table shows all required columns
- [ ] Index table sorts by id, name, year_published, created_at
- [ ] Show page displays all sections in correct order
- [ ] items_json, raw_html, simplified_html, formatted_text displayed LAST
- [ ] items_json pretty-printed with proper formatting
- [ ] Albums table shows position, title, artists, year
- [ ] Long text fields truncated with expand option

### Form Validation
- [ ] Name required validation works
- [ ] URL format validation works
- [ ] num_years_covered > 0 validation works
- [ ] Status enum dropdown shows all statuses
- [ ] All boolean flags render as checkboxes
- [ ] Error messages display correctly

### Navigation & UX
- [ ] Sidebar shows "Lists: Albums" link under Music section
- [ ] Back buttons navigate correctly
- [ ] Cancel buttons navigate correctly
- [ ] Flash messages display on success/error
- [ ] Empty states show appropriate messages
- [ ] All turbo_frame navigation works correctly

### Authorization
- [ ] Non-admin/editor users redirected to home
- [ ] Admin users can access all pages
- [ ] Editor users can access all pages

### Performance
- [ ] No N+1 queries on index page
- [ ] No N+1 queries on show page
- [ ] Pagination works correctly
- [ ] Eager loading used for all associations

---

## Deviations from Previous Phases

### 1. No Actions
**Previous phases** included execute_action, bulk_action, and index_action endpoints with custom actions.

**This phase**: Basic CRUD only. Actions deferred to Phase 9 (future):
- EnrichItemsJson
- ValidateItemsJson
- ImportItemsFromJson

**Reason**: Focus on getting basic admin interface working first, actions later.

### 2. No Search
**Previous phases** included OpenSearch integration with autocomplete endpoint.

**This phase**: No search functionality.

**Reason**: Music::Albums::List doesn't use OpenSearch indexing. Lists are few enough to browse with sort/pagination.

### 3. No Autocomplete Endpoint
**Previous phases** included `search` collection route returning JSON.

**This phase**: No search endpoint needed.

**Reason**: Lists don't appear in autocomplete dropdowns in other admin interfaces.

### 4. Items JSON Display
**Avo interface**: Used fancy widget with validation, enrichment, and import actions.

**This phase**: Simple pretty-printed JSON in `<pre>` tag.

**Reason**: Complex items_json workflow deferred to Phase 9. Just show the data for now.

### 5. Base Controller Pattern
**Phase 1-5** (Artists, Albums, Songs, Album Artists, Song Artists): Standalone controllers without base classes.

**Phase 6-7** (Ranking Configurations): Introduced base controller pattern (`Admin::Music::RankingConfigurationsController` with Albums/Songs subclasses).

**This phase** (Album Lists): Follows Phase 6-7 pattern with base controller.
- Base: `Admin::Music::ListsController` (shared CRUD logic)
- Albums: `Admin::Music::Albums::ListsController` (inherits from base)
- Future Songs: `Admin::Music::Songs::ListsController` (Phase 9+)

**Reason**: Lists will eventually have both Albums and Songs variants. Using base controller pattern avoids code duplication and follows the proven approach from ranking configurations.

**Future Base Controller**: When other domains are implemented (Books, Movies, Games), we may create an `Admin::ListsController` base class that `Admin::Music::ListsController` inherits from. For now, music-specific base is sufficient.

---

## Files to Create

**Controllers:**
- `app/controllers/admin/music/lists_controller.rb` - Base controller with shared CRUD logic
- `app/controllers/admin/music/albums/lists_controller.rb` - Albums-specific controller (inherits from base)

**Views:**
- `app/views/admin/music/albums/lists/index.html.erb` - List view
- `app/views/admin/music/albums/lists/show.html.erb` - Detail view
- `app/views/admin/music/albums/lists/new.html.erb` - Create form
- `app/views/admin/music/albums/lists/edit.html.erb` - Edit form
- `app/views/admin/music/albums/lists/_form.html.erb` - Shared form partial
- `app/views/admin/music/albums/lists/_table.html.erb` - Table partial for turbo frames

**Tests:**
- `test/controllers/admin/music/albums/lists_controller_test.rb` - Controller tests

---

## Files to Modify

- `config/routes.rb` - Add lists resources BEFORE albums resources (see route ordering section)
- `app/views/admin/shared/_sidebar.html.erb` - Add Album Lists link under Music section

---

## Testing Requirements

### Controller Tests (~22 tests)

**CRUD tests (7):**
- index action renders
- show action renders
- new action renders
- create with valid params
- create with invalid params
- update with valid params
- update with invalid params
- destroy action

**Sorting tests (2):**
- sort by allowed columns
- reject invalid sort column

**Pagination test (1):**
- paginate lists correctly

**Authorization tests (2):**
- require admin or editor role
- redirect non-admin users

**N+1 prevention tests (2):**
- no N+1 on index
- no N+1 on show

**Display tests (4):**
- items_json displayed last
- long fields truncated
- albums table renders
- empty albums message

**Error handling (2):**
- invalid album_list id
- validation error rendering

**Form tests (2):**
- form renders all fields
- checkboxes render correctly

**Target Coverage**: 100% for controller public methods

---

## Implementation Notes

*[This section will be filled out during/after implementation]*

### Approach Taken
*To be documented during implementation*

### Key Files Created
*To be documented during implementation*

### Key Files Modified
*To be documented during implementation*

### Challenges Encountered
*To be documented during implementation*

---

## Deviations from Plan

*[Document any changes from this spec during implementation]*

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture
- Respect snippet budget (≤40 lines per snippet unless unavoidable)
- Do not duplicate authoritative code; **link to files by path**
- Use Rails generators for controller creation (ensures test file created)

### Required Outputs
- All files listed in "Files to Create" section
- All files listed in "Files to Modify" section with correct changes
- Passing tests for all Acceptance Criteria
- Updated sections: "Implementation Notes", "Deviations from Plan"

### Sub-Agent Plan
1. **codebase-pattern-finder** → Collect comparable patterns from Artists/Albums controllers
2. **codebase-analyzer** → Verify Music::Albums::List model structure and associations
3. **general-purpose** → Implement controller, views, and tests following patterns
4. **technical-writer** → Update docs and cross-refs after implementation

### Commands to Run
```bash
# Navigate to Rails root
cd web-app

# Generate controllers with test files
# Base controller (no generator - create manually)
# Albums controller
bin/rails generate controller Admin::Music::Albums::Lists index show new edit

# Run tests after implementation
bin/rails test test/controllers/admin/music/albums/lists_controller_test.rb
```

### Key References

**Pattern Sources - Base Controller:**
- Base controller pattern: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/ranking_configurations_controller.rb`
- Subclass pattern: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/albums/ranking_configurations_controller.rb`

**Pattern Sources - Views:**
- Index view: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/artists/index.html.erb`
- Show view: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/artists/show.html.erb`
- Form: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/artists/_form.html.erb`
- Table: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/artists/_table.html.erb`

**Model:**
- `/home/shane/dev/the-greatest/web-app/app/models/music/albums/list.rb`
- `/home/shane/dev/the-greatest/web-app/app/models/list.rb` (parent class)

**Routes:**
- Route ordering pattern: `/home/shane/dev/the-greatest/web-app/config/routes.rb:40-121` (ranking configurations)

**Documentation:**
- `/home/shane/dev/the-greatest/docs/models/music/albums_list.md`

---

## Related Tasks

**Previous Phases:**
- [Phase 1: Artists](completed/072-custom-admin-phase-1-artists.md)
- [Phase 2: Albums](completed/073-custom-admin-phase-2-albums.md)
- [Phase 3: Album Artists](completed/074-custom-admin-phase-3-album-artists.md)
- [Phase 4: Songs](completed/075-custom-admin-phase-4-songs.md)
- [Phase 5: Song Artists](completed/076-custom-admin-phase-5-song-artists.md)
- [Phase 6: Ranking Configs](completed/077-custom-admin-phase-6-ranking-configs.md)
- [Phase 7: Artist Ranking Configs](completed/078-custom-admin-phase-7-artist-ranking-configs.md)

**Future Phases:**
- Phase 9: Album Lists Actions (EnrichItemsJson, ValidateItemsJson, ImportItemsFromJson)
- Phase 10: Song Lists (if needed)
- Phase 11: Other domains (Movies, Books, Games)
- Phase 12: Avo Removal

---

## Definition of Done

- [ ] All Acceptance Criteria pass (tests + manual verification)
- [ ] No N+1 queries on index or show pages
- [ ] Docs updated (task file, todo.md)
- [ ] Links to authoritative code present
- [ ] No large code dumps in spec
- [ ] Security/auth reviewed for all paths
- [ ] Performance constraints met
- [ ] All tests passing (100% coverage target)
