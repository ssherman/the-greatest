# 111 - Fix AiChat Music Admin Scoping for List STI Subclasses

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-01-07
- **Started**: 2026-01-07
- **Completed**: 2026-01-07
- **Developer**: Claude Opus 4.5

## Overview
Fix the Admin Music AI Chats controller to correctly filter AiChats with List parents by their STI subclass type. Rails intentionally stores the base class name (`List`) in polymorphic `parent_type` columns, so we need to use JOINs to filter by the actual STI type stored in `lists.type`.

**Scope:**
- Add a scope to AiChat model for filtering by List STI subclasses
- Update the admin music controller to use the new scope
- Keep the solution extensible for future domains (Books, Movies, Games)

**Non-goals:**
- Changing Rails' default polymorphic STI behavior (this is intentional by design)
- Data migrations to change parent_type values
- Non-music domain controllers (future work)

## Context & Links
- Related specs: `docs/specs/completed/110-admin-ai-chats-index-show.md` (discovered issue)
- AiChat model: `app/models/ai_chat.rb:30-52`
- Admin controller: `app/controllers/admin/music/ai_chats_controller.rb`
- Base List model: `app/models/list.rb:41-148`
- List STI subclasses:
  - `app/models/music/albums/list.rb:43` - `Music::Albums::List`
  - `app/models/music/songs/list.rb:43` - `Music::Songs::List`

## Problem Analysis

### Why Rails Stores Base Class Name
Rails polymorphic associations with STI models store the **base class name** by design:
1. **Normalization**: The STI type is already in `lists.type` - storing it again would be denormalization
2. **STI class changes**: If an object's STI type changes, polymorphic references don't break
3. **Table identification**: The polymorphic type column identifies the *table*, not the subclass

### Current Behavior
When `BaseTask#create_chat!` creates an AiChat with `parent: music_albums_list`:
- `parent_type` is stored as `"List"` (base class)
- `parent_id` points to the list record
- The list's actual type (`"Music::Albums::List"`) is in `lists.type`

### Impact on Admin Controller
The controller at `app/controllers/admin/music/ai_chats_controller.rb:30-33`:
```ruby
def music_scoped_ai_chats
  AiChat.where(parent_type: MUSIC_PARENT_TYPES)
    .or(AiChat.where(parent_type: nil))
end
```

This queries for `parent_type IN ('Music::Albums::List', 'Music::Songs::List', ...)` but records have `parent_type = 'List'`, so music list AiChats are excluded.

## Interfaces & Contracts

### New Scope on AiChat Model

Add a scope that joins to the lists table and filters by STI type:

```ruby
# reference only - pattern for STI-aware polymorphic filtering
scope :with_list_parent_types, ->(sti_types) {
  joins("INNER JOIN lists ON lists.id = ai_chats.parent_id AND ai_chats.parent_type = 'List'")
    .where(lists: { type: sti_types })
}
```

### Updated Controller Logic

The `music_scoped_ai_chats` method needs to combine:
1. Direct parent types: `Music::Artist`, `Music::Album`, `Music::Song`
2. List STI subtypes via JOIN: `Music::Albums::List`, `Music::Songs::List`
3. Null parent types (chats with no parent)

```ruby
# reference only - updated scoping approach
MUSIC_DIRECT_PARENT_TYPES = %w[Music::Artist Music::Album Music::Song].freeze
MUSIC_LIST_STI_TYPES = %w[Music::Albums::List Music::Songs::List].freeze

def music_scoped_ai_chats
  direct_types = AiChat.where(parent_type: MUSIC_DIRECT_PARENT_TYPES)
  list_types = AiChat.with_list_parent_types(MUSIC_LIST_STI_TYPES)
  no_parent = AiChat.where(parent_type: nil)

  direct_types.or(list_types).or(no_parent)
end
```

### Behaviors (pre/postconditions)

#### Scope: with_list_parent_types
- **Input**: Array of STI type strings (e.g., `['Music::Albums::List', 'Music::Songs::List']`)
- **Output**: AiChats where `parent_type = 'List'` AND `lists.type IN (input types)`
- **Edge case**: Empty array returns no records
- **Edge case**: Invalid type strings return no records (no error)

#### Controller: music_scoped_ai_chats
- **Postcondition**: Returns AiChats with:
  - `parent_type` in `['Music::Artist', 'Music::Album', 'Music::Song']`, OR
  - `parent_type = 'List'` AND `lists.type` in `['Music::Albums::List', 'Music::Songs::List']`, OR
  - `parent_type IS NULL`
- **Invariant**: No AiChats from other domains (Books, Movies, Games) are included

### Non-Functionals
- **Performance**: JOIN should use existing indexes on `ai_chats.parent_type`, `ai_chats.parent_id`, and `lists.type`
- **N+1**: No additional queries introduced; `includes(:parent)` still works
- **Extensibility**: Pattern should be reusable for future domain controllers

## Acceptance Criteria

### Model Scope
- [x] `AiChat.with_list_parent_types(['Music::Albums::List'])` returns AiChats with Music::Albums::List parents
- [x] `AiChat.with_list_parent_types(['Music::Songs::List'])` returns AiChats with Music::Songs::List parents
- [x] Scope can be combined with other scopes (e.g., `.includes(:parent)`)
- [x] Scope returns empty relation for empty array input
- [x] Scope is chainable with `.where()` for combining with other conditions (`.or()` not compatible with JOINs)

### Admin Controller
- [x] Index page shows AiChats with `Music::Albums::List` parents
- [x] Index page shows AiChats with `Music::Songs::List` parents
- [x] Index page shows AiChats with `Music::Artist`, `Music::Album`, `Music::Song` parents
- [x] Index page shows AiChats with no parent (user-only chats)
- [x] Index page excludes AiChats with `Books::List`, `Movies::List`, `Games::List` parents
- [x] Show page works for AiChats with music list parents

### Tests
- [x] Unit test for `with_list_parent_types` scope with various inputs
- [x] Controller test verifying music list AiChats appear in index
- [x] Controller test verifying non-music list AiChats are excluded

### Golden Examples

**Querying music list AiChats:**
```text
Database state:
  ai_chats:
  | id | parent_type | parent_id |
  | 1  | List        | 100       |  # lists.type = "Music::Albums::List"
  | 2  | List        | 200       |  # lists.type = "Books::List"
  | 3  | Music::Artist | 300     |

Query: AiChat.with_list_parent_types(['Music::Albums::List'])
Result: [AiChat#1]

Query: music_scoped_ai_chats (controller)
Result: [AiChat#1, AiChat#3]  # excludes AiChat#2 (Books::List)
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Do NOT try to change Rails' default polymorphic STI behavior.
- Respect snippet budget (≤40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → find similar JOIN scope patterns in codebase
2) codebase-analyzer → verify controller and scope integration
3) technical-writer → update docs and cross-refs after implementation

### Test Seed / Fixtures
- Add AiChat fixtures with `Music::Albums::List` and `Music::Songs::List` parents
- Ensure `test/fixtures/lists.yml` has music list fixtures with correct STI types
- Add `Books::List` AiChat fixture to verify exclusion

### Implementation Checklist
1. Add `with_list_parent_types` scope to `app/models/ai_chat.rb`
2. Update `app/controllers/admin/music/ai_chats_controller.rb`:
   - Split `MUSIC_PARENT_TYPES` into direct types and list STI types
   - Update `music_scoped_ai_chats` to use JOIN for list types
3. Update `test/fixtures/ai_chats.yml` with music list parent fixtures
4. Add scope tests to `test/models/ai_chat_test.rb`
5. Update controller tests in `test/controllers/admin/music/ai_chats_controller_test.rb`
6. Run full test suite
7. Update documentation

### Future Extensibility
The pattern supports future domain controllers:
```ruby
# Future: Books admin controller
BOOKS_LIST_STI_TYPES = %w[Books::List].freeze
AiChat.with_list_parent_types(BOOKS_LIST_STI_TYPES)

# Future: Movies admin controller
MOVIES_LIST_STI_TYPES = %w[Movies::List].freeze
AiChat.with_list_parent_types(MOVIES_LIST_STI_TYPES)
```

---

## Implementation Notes (living)
- **Approach taken**: Added `with_list_parent_types` scope to AiChat model that uses INNER JOIN to lists table, then combined results using `.or()` with ID-based filtering to avoid Rails' ".or() incompatible with joins" limitation.
- **Important decisions**:
  - Used `pluck(:id)` to get list chat IDs, then combined with `.or(AiChat.where(id: list_chat_ids))` since Rails doesn't allow `.or()` between relations with different JOIN structures
  - Added early return `return none if sti_types.blank?` to handle empty/nil input gracefully
  - Used explicit `parent_type: "List"` and `parent_id` in fixtures (with `ActiveRecord::FixtureSet.identify`) since Rails fixture polymorphic syntax stores the specified class name, not what Rails would naturally store

### Key Files Touched (paths only)
- `app/models/ai_chat.rb` - Added `with_list_parent_types` scope
- `app/controllers/admin/music/ai_chats_controller.rb` - Split constants, updated `music_scoped_ai_chats`
- `test/fixtures/ai_chats.yml` - Added music list parent AiChat fixtures with correct `parent_type: "List"`
- `test/models/ai_chat_test.rb` - Added 8 tests for `with_list_parent_types` scope
- `test/controllers/admin/music/ai_chats_controller_test.rb` - Added 4 tests for music list STI parent handling

### Challenges & Resolutions
1. **Fixture polymorphic STI behavior**: Rails fixture syntax `parent: x (ClassName)` stores the specified class name directly, not the base class that Rails would naturally store. Resolved by manually setting `parent_type: "List"` and using `ActiveRecord::FixtureSet.identify(:fixture_name)` for parent_id.
2. **`.or()` incompatible with JOINs**: Rails doesn't allow `.or()` between relations with different structural compositions (one with JOIN, one without). Resolved by fetching list chat IDs first with `pluck(:id)`, then using `.or(AiChat.where(id: list_chat_ids))`.

### Deviations From Plan
- **Scope chainability with `.or()`**: The spec mentioned the scope should be "chainable with `.or()`", but Rails doesn't support this for JOIN-based scopes. The scope is chainable with `.where()`, `.includes()`, and other methods. The controller works around this limitation using the ID-based approach.

## Acceptance Results
- **Date**: 2026-01-07
- **Verifier**: Claude Opus 4.5
- **Artifacts**: All 2822 tests pass (38 specific to this feature)

## Future Improvements
- Add similar scoping for Books, Movies, Games admin controllers when implemented
- Consider a more generic `with_sti_parent_type` scope if pattern is used frequently

## Related PRs
- (To be added when PR is created)

## Documentation Updated
- [x] Spec file updated with implementation notes
- [x] `docs/models/ai_chat.md` - Created with full model documentation including `with_list_parent_types` scope
- [x] `docs/controllers/admin/music/ai_chats_controller.md` - Created with controller documentation
