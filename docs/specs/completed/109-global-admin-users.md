# 076 - Global Admin Users CRUD Interface

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-07
- **Started**: 2026-01-07
- **Completed**: 2026-01-07
- **Developer**: Claude Code

## Overview
Implement a CRUD interface for Users in the admin system (not Avo). Users are created via Firebase authentication on login, so this interface provides index (with search), show, edit, update, and destroy actions only. Users are a global resource not tied to any specific domain.

**Scope:**
- Index page with email search
- Show page with user details
- Edit/Update for specific editable fields
- Delete with confirmation (on index and show pages)

**Non-goals:**
- Create action (users created via authentication)
- Bulk delete
- Any actions beyond delete

## Context & Links
- Related patterns: `app/controllers/admin/penalties_controller.rb` (global resource pattern)
- User model: `app/models/user.rb:34-75`
- User schema: `db/schema.rb:502-527`
- Existing Avo resource (for reference only): `app/avo/resources/user.rb`
- Admin base controller: `app/controllers/admin/base_controller.rb`

## Interfaces & Contracts

### Domain Model (no changes)
User model already exists. No migrations required.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/users | List users with pagination and search | `q` (email search), `page` | admin |
| GET | /admin/users/:id | Show user details | - | admin |
| GET | /admin/users/:id/edit | Edit user form | - | admin |
| PATCH | /admin/users/:id | Update user | `user` params | admin |
| DELETE | /admin/users/:id | Delete user | - | admin |

> Source of truth: `config/routes.rb`

### Request/Response Schemas

#### Update User (PATCH /admin/users/:id)
```json
{
  "type": "object",
  "required": ["user"],
  "properties": {
    "user": {
      "type": "object",
      "properties": {
        "email": { "type": "string", "format": "email" },
        "display_name": { "type": "string", "nullable": true },
        "name": { "type": "string", "nullable": true },
        "role": { "type": "string", "enum": ["user", "admin", "editor"] },
        "stripe_customer_id": { "type": "string", "nullable": true }
      }
    }
  }
}
```

### Field Classification

#### Editable Fields (in edit form)
| Field | Type | Notes |
|-------|------|-------|
| `email` | string | Required, unique. Admins may need to correct typos. |
| `display_name` | string | User's public display name |
| `name` | string | User's full name |
| `role` | enum | user/admin/editor - Critical for access control |
| `stripe_customer_id` | string | May need admin correction for billing issues |

#### Read-Only Display Fields (show page only)
| Field | Type | Notes |
|-------|------|-------|
| `id` | integer | Primary key |
| `photo_url` | string | Profile photo (display image if present) |
| `external_provider` | enum | How they signed up (facebook/twitter/google/apple/password) |
| `original_signup_domain` | string | Domain where user first signed up |
| `email_verified` | boolean | Whether email has been verified |
| `confirmed_at` | datetime | When email was confirmed |
| `last_sign_in_at` | datetime | Last sign-in timestamp |
| `sign_in_count` | integer | Number of sign-ins |
| `created_at` | datetime | Account creation date |
| `updated_at` | datetime | Last update timestamp |

#### Hidden Fields (not displayed in admin UI)
| Field | Reason |
|-------|--------|
| `auth_uid` | Internal authentication ID |
| `auth_data` | Raw auth response (sensitive) |
| `provider_data` | Raw provider data (sensitive) |
| `confirmation_token` | Security token |
| `confirmation_sent_at` | Internal tracking |

### Behaviors (pre/postconditions)

#### Index
- **Preconditions**: Current user must be admin
- **Search behavior**: When `q` param present, filter users by email using wildcard match (`WHERE email ILIKE '%query%'`)
- **Sorting**: Default sort by `created_at DESC` (newest first)
- **Pagination**: 25 items per page using Pagy

#### Update
- **Preconditions**: Current user must be admin; target user must exist
- **Postconditions**: User record updated; flash notice displayed
- **Validation**: Email must be present, unique; role must be valid enum value
- **Edge case**: Changing own role from admin should still work (no self-protection)

#### Destroy
- **Preconditions**: Current user must be admin; target user must exist
- **Postconditions**: User record deleted; dependent records handled per model associations
- **Confirmation**: Browser confirm dialog via `data-turbo-confirm`
- **Redirect**: After delete, redirect to index with success notice

### Non-Functionals
- **Performance**: Index page should load in <500ms with search
- **N+1**: No N+1 queries on index (user has no eager-loaded associations needed)
- **Security**: Only admin role can access (not editor)
- **Responsiveness**: Mobile-friendly using existing admin layout patterns

## Acceptance Criteria

### Index Page
- [ ] Index displays users in a table with: ID, Email, Display Name, Role, Last Sign In, Actions
- [ ] Search input filters users by email (case-insensitive partial match)
- [ ] Search uses Turbo Frame for partial page updates
- [ ] Pagination shows 25 users per page
- [ ] Each row has View, Edit, and Delete action buttons
- [ ] Delete button shows confirmation dialog before proceeding
- [ ] Empty state shown when no users match search

### Show Page
- [ ] Displays all read-only fields listed above in organized cards
- [ ] Shows profile photo if `photo_url` present
- [ ] Header includes Edit and Delete buttons
- [ ] Delete button shows confirmation dialog with user email
- [ ] Back button links to users index

### Edit Page
- [ ] Form displays only editable fields (email, display_name, name, role, stripe_customer_id)
- [ ] Role field is a select dropdown with user/admin/editor options
- [ ] Validation errors display per-field with red styling
- [ ] Cancel button returns to show page
- [ ] Save redirects to show page with success notice

### Authorization
- [ ] All actions require admin role (not editor)
- [ ] Non-admin users redirected to domain root with access denied message

### Golden Examples

**Index with search:**
```text
Input: GET /admin/users?q=john@example
Output: Table showing users with emails containing "john@example"
```

**Update user role:**
```text
Input: PATCH /admin/users/123 { user: { role: "editor" } }
Output: User role updated, redirect to show page with "User updated successfully." notice
```

**Delete with cascade:**
```text
Input: DELETE /admin/users/456 (confirmed)
Output: User deleted, dependent records (ranking_configurations, penalties, ai_chats) destroyed,
        submitted_lists nullified, redirect to index with "User deleted successfully." notice
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Model after `Admin::PenaltiesController` for global resource pattern.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Only admin role (not editor) should access users management.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> use patterns from `admin/penalties_controller.rb` and views
2) codebase-analyzer -> verify User model associations and dependent destroy behavior
3) technical-writer -> update docs and cross-refs after implementation

### Test Seed / Fixtures
- `test/fixtures/users.yml` already contains: `admin_user`, `editor_user`, `regular_user`
- No new fixtures needed

### Implementation Checklist
1. Add routes to `config/routes.rb` under global admin namespace
2. Create `app/controllers/admin/users_controller.rb`
3. Create views in `app/views/admin/users/`:
   - `index.html.erb`
   - `_table.html.erb`
   - `show.html.erb`
   - `edit.html.erb`
   - `_form.html.erb`
4. Add "Users" link to admin sidebar (global section)
5. Create controller tests in `test/controllers/admin/users_controller_test.rb`

---

## Implementation Notes (living)
- Approach taken: Followed `Admin::PenaltiesController` pattern for global resource CRUD
- Important decisions:
  - Used `Admin::SearchComponent` for email search with Turbo Frames
  - Added separate `require_admin_role!` authorization (admin only, not editor)
  - Used ILIKE for case-insensitive email search (no OpenSearch needed)
  - Show page displays related data counts (ranking_configurations, penalties, ai_chats, submitted_lists)

### Key Files Touched (paths only)
- `config/routes.rb` - Added `resources :users, except: [:new, :create]`
- `app/controllers/admin/users_controller.rb` - Full CRUD controller
- `app/views/admin/users/index.html.erb` - Index with search component
- `app/views/admin/users/_table.html.erb` - Table with pagination
- `app/views/admin/users/show.html.erb` - Detailed user view with cards
- `app/views/admin/users/edit.html.erb` - Edit wrapper
- `app/views/admin/users/_form.html.erb` - Form with editable fields
- `app/views/admin/shared/_sidebar.html.erb` - Enabled Users link in Global section
- `test/controllers/admin/users_controller_test.rb` - 15 tests covering all acceptance criteria

### Challenges & Resolutions
- Authorization: Base controller allows admin OR editor, but Users management needed admin-only. Added separate `require_admin_role!` before_action.

### Deviations From Plan
- None

## Acceptance Results
- Date: 2026-01-07
- Verifier: Automated tests (15 tests, 19 assertions, 0 failures)
- All acceptance criteria covered by tests

## Future Improvements
- Add bulk actions if needed later
- Consider password reset capability for password-based users
- Add user activity log/audit trail

## Related PRs
- #...

## Documentation Updated
- [x] `documentation.md` - No changes needed (template unchanged)
- [x] Class docs - Created `docs/controllers/admin/users_controller.md`
