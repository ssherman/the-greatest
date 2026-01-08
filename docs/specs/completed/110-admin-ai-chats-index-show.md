# 110 - Admin AI Chats Index & Show Interface

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-07
- **Started**: 2026-01-07
- **Completed**: 2026-01-07
- **Developer**: Claude

## Overview
Implement read-only index and show pages for AI Chats in the new admin system (not Avo). AI Chats are created programmatically and have polymorphic relationships to various parent models. This interface provides visibility into AI interactions without CRUD operations.

**Scope:**
- Base controller with shared logic for all domains
- Music-scoped controller filtering to music-related parent types only
- Index page sorted by `created_at DESC` (no filters needed)
- Show page with full chat details
- Smart linking to parent admin pages where available

**Non-goals:**
- Create, edit, update, delete actions (chats created programmatically)
- Search or filtering on index
- Bulk actions
- Non-music domain controllers (future work)

## Context & Links
- Related specs: `docs/specs/completed/012-ai-chats-model.md` (model implementation)
- AiChat model: `app/models/ai_chat.rb:1-51`
- Existing Avo resource (reference only): `app/avo/resources/ai_chat.rb`
- Base controller: `app/controllers/admin/base_controller.rb`
- Music base controller: `app/controllers/admin/music/base_controller.rb`
- Similar read-only pattern: `app/controllers/admin/music/ranked_items_controller.rb`
- Users controller (global pattern): `app/controllers/admin/users_controller.rb`

## Interfaces & Contracts

### Domain Model (no changes)
AiChat model already exists. No migrations required.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/ai_chats | List all AI chats (music types only) | `page` | admin/editor |
| GET | /admin/ai_chats/:id | Show AI chat details | - | admin/editor |

> Source of truth: `config/routes.rb`

### Controller Architecture

**Base Controller** (`app/controllers/admin/ai_chats_controller.rb`):
- Inherits from `Admin::BaseController`
- Contains all shared logic for index and show
- Defines abstract method `parent_type_scope` for filtering
- Handles polymorphic parent linking

**Music Controller** (`app/controllers/admin/music/ai_chats_controller.rb`):
- Inherits from `Admin::Music::BaseController`
- Delegates to or includes shared logic from base
- Scopes to music-related parent types: `Music::Artist`, `Music::Album`, `Music::Song`

### Parent Type Routing Map

| parent_type | Has Admin Show Page? | Path Helper |
|-------------|---------------------|-------------|
| `Music::Artist` | Yes | `admin_artist_path(parent)` |
| `Music::Album` | Yes | `admin_album_path(parent)` |
| `Music::Song` | Yes | `admin_song_path(parent)` |
| `List` | Conditional | `admin_albums_list_path` / `admin_songs_list_path` based on `list.type` |
| `Category` | No (placeholder link) | - |
| `Movies::Movie` | No (not in music admin) | - |

### Behaviors (pre/postconditions)

#### Index
- **Preconditions**: Current user must be admin or editor
- **Scope**: Only AI chats with music-related parent types (or user-only for music)
- **Sorting**: `created_at DESC` (newest first, hardcoded)
- **Pagination**: 25 items per page using Pagy
- **Eager loading**: Include `parent` association for display

#### Show
- **Preconditions**: Current user must be admin or editor; AI chat must exist
- **Display**: All fields including JSONB data formatted for readability
- **Parent link**: Smart link to parent's admin show page if available

### Non-Functionals
- **Performance**: Index page should load in <500ms
- **N+1**: No N+1 queries - eager load `parent` association
- **Security**: Admin or editor role required
- **Responsiveness**: Mobile-friendly using existing admin layout patterns

## Acceptance Criteria

### Index Page
- [x] Index displays AI chats in a table with: ID, Chat Type, Provider, Model, Parent (linked), Created At
- [x] Table sorted by `created_at DESC` (no sort controls needed)
- [x] Pagination shows 25 chats per page
- [x] Each row has a View action button linking to show page
- [x] Parent column shows type and name/title with link to parent admin page (where available)
- [x] Parent column shows user email with link if no parent but has user
- [x] Empty state shown when no AI chats exist

### Show Page
- [x] Header shows "AI Chat #ID" with back button to index
- [x] Basic Information card displays: chat_type, provider, model, temperature, json_mode
- [x] Parent card shows parent type and links to parent admin page (if available)
- [x] User card shows associated user with link to admin user page (if present)
- [x] Messages card displays JSONB messages in readable format (JSON viewer or formatted list)
- [x] Parameters card displays JSONB parameters if present
- [x] Response Schema card displays JSONB schema if present
- [x] Raw Responses card displays JSONB responses in readable format
- [x] Timestamps shown: created_at, updated_at

### Authorization
- [x] All actions require admin or editor role
- [x] Non-authorized users redirected to domain root with access denied message

### Navigation
- [x] "AI Chats" link added to admin sidebar under Music section
- [x] Back button on show page returns to index

### Golden Examples

**Index with various parent types:**
```text
Input: GET /admin/ai_chats
Output: Table showing:
| ID | Type | Provider | Model | Parent | Created |
| 42 | ranking | openai | gpt-4 | Music::Album: Dark Side... | Jan 7, 2026 |
| 41 | analysis | anthropic | claude-3 | Music::Artist: Pink Floyd | Jan 6, 2026 |
| 40 | general | gemini | gemini-pro | - | Jan 6, 2026 |
```

**Show page with parent link:**
```text
Input: GET /admin/ai_chats/42
Output:
- Header: AI Chat #42
- Basic Info: chat_type=ranking, provider=openai, model=gpt-4, temp=0.2
- Parent: Music::Album → [Dark Side of the Moon] (clickable link to admin_album_path)
- Messages: [formatted JSON array of conversation]
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Model after `Admin::UsersController` for read-only pattern (no create/edit/delete).
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Use polymorphic parent linking pattern from `Admin::ResourcesHelper`.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → find similar read-only controller patterns
2) codebase-analyzer → verify AiChat associations and parent types
3) technical-writer → update docs and cross-refs after implementation

### Test Seed / Fixtures
- `test/fixtures/ai_chats.yml` already contains test data
- May need additional fixtures for music-scoped parents

### Implementation Checklist
1. Add routes to `config/routes.rb`:
   - Under music admin namespace: `resources :ai_chats, only: [:index, :show]`
2. Create `app/controllers/admin/music/ai_chats_controller.rb`:
   - Inherit from `Admin::Music::BaseController`
   - Implement `index` with scoping and pagination
   - Implement `show` with eager loading
   - Add `admin_parent_path` helper for polymorphic linking
3. Create views in `app/views/admin/music/ai_chats/`:
   - `index.html.erb` - page layout with table
   - `_table.html.erb` - table partial with pagination
   - `show.html.erb` - detail page with cards
4. Add helper methods for polymorphic parent linking:
   - Create `Admin::AiChatsHelper` or extend `Admin::ResourcesHelper`
   - Handle all parent types with fallback for unsupported types
5. Add "AI Chats" link to admin sidebar under Music section
6. Create controller tests in `test/controllers/admin/music/ai_chats_controller_test.rb`

### JSONB Display Approach
For `messages`, `parameters`, `response_schema`, and `raw_responses` fields:
- Use `<pre><code>` blocks with JSON formatting
- Apply `whitespace-pre-wrap` for readability
- Consider collapsible sections for long content

### Helper Method for Parent Links (reference)
```ruby
# reference only - pattern for polymorphic parent linking
def admin_ai_chat_parent_path(ai_chat)
  parent = ai_chat.parent
  return nil unless parent

  case parent
  when Music::Artist then admin_artist_path(parent)
  when Music::Album then admin_album_path(parent)
  when Music::Song then admin_song_path(parent)
  when List then admin_list_path_for(parent)
  else nil
  end
end
```

---

## Implementation Notes (living)
- Approach taken: Followed existing Admin::UsersController read-only pattern
- Important decisions:
  - Created dedicated helper module `Admin::AiChatsHelper` for parent linking and badge styling
  - Scoped index AND show to music-related parents only (Music::Artist, Music::Album, Music::Song, Music::Albums::List, Music::Songs::List) plus chats with nil parent
  - Non-music AI chats (e.g., Books::List parent) return 404 on show
  - Used Pagy for pagination with 25 items per page
  - Added badge color coding for chat_type and provider enums
  - JSONB fields displayed with JSON.pretty_generate in pre/code blocks

### Key Files Touched (paths only)
- `config/routes.rb`
- `app/controllers/admin/music/ai_chats_controller.rb`
- `app/views/admin/music/ai_chats/index.html.erb`
- `app/views/admin/music/ai_chats/_table.html.erb`
- `app/views/admin/music/ai_chats/show.html.erb`
- `app/helpers/admin/ai_chats_helper.rb`
- `app/views/admin/shared/_sidebar.html.erb`
- `test/controllers/admin/music/ai_chats_controller_test.rb`
- `test/fixtures/ai_chats.yml`

### Challenges & Resolutions
- Polymorphic parent linking required type-based case statement in helper
- Added music-related AI chat fixtures for testing

### Deviations From Plan
- Spec mentioned base controller at Admin::AiChatsController but implemented directly in Admin::Music namespace since only music domain is currently needed
- Helper placed in Admin::AiChatsHelper (not Admin::ResourcesHelper) to keep it self-contained

## Acceptance Results
- Date: 2026-01-07
- Verifier: Claude (automated tests)
- Artifacts: 16 passing controller tests, all 2810 project tests passing

## Future Improvements
- Add search/filter functionality if needed
- Extend to other domains (Movies, Books, Games) when their admins are built
- Add message count badge to index table
- Consider JSON syntax highlighting for better readability

## Related PRs
- #...

## Documentation Updated
- [x] `docs/controllers/admin/music/ai_chats_controller.md`
- [x] `docs/helpers/admin/ai_chats_helper.md`
