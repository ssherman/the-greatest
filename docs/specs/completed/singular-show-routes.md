# Singular Show Routes for Albums and Songs

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-18
- **Started**: 2026-01-18
- **Completed**: 2026-01-18
- **Developer**: Claude

## Overview
Change album and song show page routes from plural to singular form (`/album/:slug` and `/song/:slug` instead of `/albums/:id` and `/songs/:id`). This eliminates route collisions with year filtering routes (e.g., `/albums/1990s`) and albums with numeric slugs (e.g., Van Halen's "1984").

**Non-goals**: Changing index/list routes (those remain plural: `/albums`, `/songs`).

## Context & Links
- Related tasks: `docs/specs/year-filtering-ranked-items.md` (year filtering implementation)
- Source files (authoritative):
  - `config/routes.rb`
  - `app/controllers/music/albums_controller.rb`
  - `app/controllers/music/songs_controller.rb`
- Problem: Album "1984" has slug `1984`, which collides with `/albums/1984` year filter route

## Interfaces & Contracts

### Endpoints

| Verb | Path | Purpose | Params | Auth |
|---|---|---|---|---|
| GET | `/album/:slug` | Show single album | slug (string) | public |
| GET | `/song/:slug` | Show single song | slug (string) | public |

**Removed routes:**
| Verb | Path | Replacement |
|---|---|---|
| GET | `/albums/:id` | `/album/:slug` |
| GET | `/songs/:id` | `/song/:slug` |

> Source of truth: `config/routes.rb`

### Behaviors

**Preconditions:**
- Slug must match an existing album/song record
- Slug is the `slug` field (not database ID)

**Postconditions:**
- Returns 200 with album/song show page
- Returns 404 if slug not found

**Edge cases:**
- Numeric slugs (e.g., "1984") now work without collision
- Old `/albums/:id` URLs return 404 (or optionally redirect)

### Redirects (optional enhancement)
Consider 301 redirects from old plural routes to new singular routes for SEO continuity:
- `/albums/abbey-road` → `/album/abbey-road`
- `/songs/hey-jude` → `/song/hey-jude`

### Non-Functionals
- No performance impact (same controller actions)
- SEO: Implement 301 redirects to preserve link equity
- Update any internal links to use new route helpers

## Acceptance Criteria
- [x] `/album/:slug` renders album show page
- [x] `/song/:slug` renders song show page
- [x] `/albums/1984` returns year-filtered list (not album show)
- [x] `/album/1984` returns Van Halen's "1984" album show page
- [x] Route helpers updated: `album_path(album)` and `song_path(song)`
- [x] All internal links use new helpers (helpers already used singular names)
- [x] Old plural show routes return 404 (no redirects - per user request)
- [x] All existing tests pass (3,128 tests, 0 failures)

### Golden Examples
```text
Input: GET /album/abbey-road
Output: 200, renders Music::Album "Abbey Road" show page

Input: GET /albums/1984
Output: 200, renders year-filtered album list for 1984

Input: GET /album/1984
Output: 200, renders Van Halen's "1984" album show page

Input: GET /song/hey-jude
Output: 200, renders Music::Song "Hey Jude" show page
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → find all usages of `album_path`, `song_path` helpers
2) codebase-analyzer → verify controller/view dependencies
3) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- Existing fixtures sufficient
- Ensure an album with numeric slug exists for collision testing

---

## Implementation Notes (living)
- Approach taken: Minimal changes - only routes and controller params updated
- Important decisions:
  - Route helper names (`album_path`, `song_path`) were already singular by Rails convention, so no view/helper changes needed
  - Admin routes kept plural (`/admin/albums/:id`) - only public routes changed
  - No backward compatibility redirects (per user decision)

### Key Files Touched (paths only)
- `config/routes.rb` (lines 34, 47 - changed `:id` to `:slug`)
- `app/controllers/music/albums_controller.rb` (line 18 - `params[:slug]`)
- `app/controllers/music/songs_controller.rb` (line 21 - `params[:slug]`)

### Challenges & Resolutions
- None - implementation was straightforward due to existing use of singular route helper names

### Deviations From Plan
- Views/helpers did not need updating - they already used singular `album_path`/`song_path` helpers which Rails auto-generates

## Acceptance Results
- Date: 2026-01-18
- Verifier: Claude
- All 3,128 tests pass

## Future Improvements
- Consider similar changes for other show routes if pattern proves beneficial

## Related PRs
-

## Documentation Updated
- [x] `documentation.md` - N/A (documentation standards file, no route-specific docs exist)
- [x] Class docs - N/A (controllers unchanged except param name)
