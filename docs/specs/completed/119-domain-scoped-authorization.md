# [119] - Domain-Scoped Authorization System

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-01-17
- **Started**: 2026-01-17
- **Completed**: 2026-01-17
- **Developer**: Claude

## Overview
Implement a domain-scoped authorization system using Pundit that allows granular permission control across media domains (music, games, books, movies). Contractors can be granted specific permission levels per domain without accessing other domains. The existing global `admin` role becomes a super-admin that bypasses all domain checks.

**Non-goals:**
- Resource-type permissions (e.g., "can edit artists but not albums") - may add later
- Audit logging - may add later
- Custom action overrides per permission

## Context & Links
- Related tasks/phases: N/A (new feature)
- Source files (authoritative):
  - `app/models/user.rb:44` - Current role enum
  - `app/controllers/admin/base_controller.rb` - Current auth pattern
  - `app/controllers/application_controller.rb:36-49` - Domain detection
- External docs:
  - [Pundit](https://github.com/varvet/pundit) - v2.5.2+, explicit Rails 8 support

## Interfaces & Contracts

### Domain Model (diffs only)

**New Table: `domain_roles`**

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| id | bigint | PK | |
| user_id | bigint | FK, NOT NULL | References users |
| domain | integer | NOT NULL | Enum: 0=music, 1=games, 2=books, 3=movies |
| permission_level | integer | NOT NULL | Enum: 0=viewer, 1=editor, 2=moderator, 3=admin |
| created_at | datetime | NOT NULL | |
| updated_at | datetime | NOT NULL | |

**Indexes:**
- `(user_id, domain)` UNIQUE - One role per user per domain
- `(domain)` - For querying by domain
- `(permission_level)` - For querying by level

**Migration path:** `db/migrate/[timestamp]_create_domain_roles.rb`

**User model changes:**
- Add `has_many :domain_roles, dependent: :destroy`
- Add domain permission helper methods

### Endpoints

| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/users/:user_id/domain_roles | List user's domain roles | - | global admin |
| POST | /admin/users/:user_id/domain_roles | Grant domain role | domain, permission_level | global admin |
| PATCH | /admin/domain_roles/:id | Update role level | permission_level | global admin |
| DELETE | /admin/domain_roles/:id | Revoke domain role | - | global admin |

> Source of truth: `config/routes.rb` (do not paste large blocks).

### Schemas (JSON)

**DomainRole Response**
```json
{
  "type": "object",
  "required": ["id", "user_id", "domain", "permission_level"],
  "properties": {
    "id": { "type": "integer" },
    "user_id": { "type": "integer" },
    "domain": { "type": "string", "enum": ["music", "games", "books", "movies"] },
    "permission_level": { "type": "string", "enum": ["viewer", "editor", "moderator", "admin"] },
    "created_at": { "type": "string", "format": "date-time" },
    "updated_at": { "type": "string", "format": "date-time" }
  }
}
```

### Behaviors (pre/postconditions)

**Permission Level Hierarchy:**
```
viewer (0)     → can_read?=true,  can_write?=false, can_delete?=false, can_manage?=false
editor (1)     → can_read?=true,  can_write?=true,  can_delete?=false, can_manage?=false
moderator (2)  → can_read?=true,  can_write?=true,  can_delete?=true,  can_manage?=false
admin (3)      → can_read?=true,  can_write?=true,  can_delete?=true,  can_manage?=true
Global Admin   → Bypasses ALL checks (existing User.role = :admin)
```

**Preconditions:**
- User must be authenticated to access any admin area
- Domain is determined from request hostname via existing `set_current_domain`
- User must have either: (a) global admin role, OR (b) domain_role for current domain

**Postconditions:**
- Actions are allowed/denied based on permission_level vs required permission
- Unauthorized access redirects to domain root with flash message

**Edge cases & failure modes:**
- User with no domain_roles and not global admin → redirect to domain root
- User with domain_role for different domain → redirect to domain root
- User with viewer trying to edit → redirect with "Editor permission required"
- Global admin with no domain_roles → still has full access everywhere

### Non-Functionals
- **Performance budgets:** Authorization check should add <1ms per request (single DB query, memoized)
- **No N+1:** Domain roles loaded with user: `User.includes(:domain_roles)`
- **Security/roles:** Only global admins can manage domain_roles
- **Backward compatibility:** Existing global `admin` and `editor` roles continue to work unchanged

## Acceptance Criteria
- [x] Pundit gem added and configured
- [x] `domain_roles` table created with proper indexes
- [x] `DomainRole` model with enum for domain and permission_level
- [x] User model has `has_many :domain_roles` and helper methods
- [x] `ApplicationPolicy` base class with domain-aware authorization
- [x] Domain-specific policies created: `Music::AlbumPolicy`, `Music::ArtistPolicy`, etc.
- [x] `Admin::BaseController` updated to check domain permissions
- [x] Admin music controllers use `authorize` calls from Pundit
- [x] `Admin::DomainRolesController` for managing user domain roles (global admin only)
- [x] Global admin bypasses all domain checks
- [x] Tests: model tests for DomainRole, controller authorization tests
- [x] Existing admin user (global admin) continues to have full access
- [x] Contractor with music-editor role can edit music but not access games/books/movies admin

### Golden Examples

**Example 1: Contractor with music-editor access**
```
Input:
  User: contractor@example.com (role: :user)
  DomainRole: domain=music, permission_level=editor
  Request: PATCH /admin/albums/123

Expected:
  Authorization passes (editor can update)
  Album is updated
```

**Example 2: Contractor trying to access wrong domain**
```
Input:
  User: contractor@example.com (role: :user)
  DomainRole: domain=music, permission_level=editor
  Request: GET /admin/games (hypothetical games admin)

Expected:
  Authorization fails
  Redirect to games_root_path with "Access denied"
```

**Example 3: Global admin with no domain_roles**
```
Input:
  User: admin@example.com (role: :admin)
  DomainRole: none
  Request: DELETE /admin/albums/123

Expected:
  Authorization passes (global admin bypasses)
  Album is deleted
```

### Optional Reference Snippet (≤40 lines, non-authoritative)
```ruby
# reference only - DomainRole model structure
class DomainRole < ApplicationRecord
  belongs_to :user

  enum :domain, { music: 0, games: 1, books: 2, movies: 3 }
  enum :permission_level, { viewer: 0, editor: 1, moderator: 2, admin: 3 }

  validates :user_id, uniqueness: { scope: :domain }

  def can_read? = true
  def can_write? = editor? || moderator? || admin?
  def can_delete? = moderator? || admin?
  def can_manage? = admin?
end
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Preserve backward compatibility with existing global admin/editor roles.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → collect comparable patterns (controller concerns, model enums)
2) codebase-analyzer → verify data flow & integration points
3) web-search-researcher → Pundit Rails 8 setup docs if needed
4) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- `test/fixtures/domain_roles.yml` - fixtures for music_editor, games_viewer, etc.
- `test/fixtures/users.yml` - add user with domain roles, user without

---

## Implementation Notes (living)
- Approach taken: Pundit with DomainRole model for domain-scoped permissions. Global admin/editor roles preserved for backward compatibility.
- Important decisions:
  - Keep global `admin` role as super-admin that bypasses all domain checks
  - Keep global `editor` role for backward compatibility (also bypasses domain checks)
  - New domain-scoped roles via `domain_roles` table for granular control
  - Permission levels: viewer (read-only), editor (create/update), moderator (+delete), admin (+manage)

### Key Files Touched (paths only)
- `Gemfile` - added Pundit gem
- `db/migrate/20260118055546_create_domain_roles.rb`
- `app/models/domain_role.rb`
- `app/models/user.rb` - added `has_many :domain_roles` and helper methods
- `app/policies/application_policy.rb` - domain-aware base policy
- `app/policies/music/album_policy.rb`
- `app/policies/music/artist_policy.rb`
- `app/policies/music/song_policy.rb`
- `app/controllers/application_controller.rb` - include Pundit::Authorization
- `app/controllers/admin/base_controller.rb` - updated authenticate_admin! for domain access
- `app/controllers/admin/domain_roles_controller.rb` - CRUD for domain roles
- `app/controllers/admin/music/albums_controller.rb` - added authorize calls
- `app/controllers/admin/music/artists_controller.rb` - added authorize calls
- `app/controllers/admin/music/songs_controller.rb` - added authorize calls
- `config/routes.rb` - added nested domain_roles routes under users
- `app/views/admin/domain_roles/index.html.erb` - UI for managing domain roles
- `app/views/admin/users/show.html.erb` - added link to domain roles
- `test/models/domain_role_test.rb` - 21 model tests
- `test/controllers/admin/domain_roles_controller_test.rb` - 10 controller tests
- `test/fixtures/domain_roles.yml` - test fixtures
- `test/fixtures/users.yml` - added contractor_user fixture

### Challenges & Resolutions
- View path helpers needed explicit `admin_user_domain_role_path` vs implicit path generation

### Deviations From Plan
- Did not create separate policy tests (testing via controller tests instead)
- Kept global `editor` role for backward compatibility (spec originally only mentioned admin)

## Acceptance Results
- Date: 2026-01-17
- Verifier: Claude
- All 31 tests pass (21 model tests, 10 controller tests)
- Authorization works for global admin, global editor, and domain-scoped roles

## Future Improvements
- Resource-type permissions (e.g., can edit artists but not albums)
- Audit logging for permission changes and admin actions
- Time-based permissions (expires_at)
- Permission approval workflow
- Add Pundit policies to other admin controllers (categories, ranking configs, etc.)

## Related PRs
- #…

## Documentation Updated
- [x] `docs/models/domain_role.md` - Created
- [ ] Class docs for policies (optional)
