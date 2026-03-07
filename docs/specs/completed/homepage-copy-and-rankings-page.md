# Homepage Copy & Rankings Page (Music + Games)

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-03-06
- **Started**: 2026-03-06
- **Completed**: 2026-03-06
- **Developer**: Claude Opus 4.6

## Overview

Add friendly, human "about the site" copy to the music and games homepages, and create a new `/rankings` page for each domain that explains how the ranking algorithm works at a high level. The rankings page includes dynamic stats, a list of active penalties, open-source callouts, and a Discord invite. All new pages use Cloudflare caching via the existing `Cacheable` concern.

**Non-goals**: Changing the ranking algorithm itself. Touching movies or books domains. Showing penalty percentages/numbers.

## Context & Links
- Existing music homepage: `app/views/music/default/index.html.erb`
- Existing games ranked items: `app/views/games/ranked_items/index.html.erb`
- Weight calculator: `app/lib/rankings/weight_calculator_v1.rb`
- Item rankings calculator: `app/lib/item_rankings/calculator.rb`
- Ranking configuration model: `app/models/ranking_configuration.rb`
- Penalty model: `app/models/penalty.rb`
- Cacheable concern: `app/controllers/concerns/cacheable.rb`
- weighted_list_rank gem: https://github.com/ssherman/weighted_list_rank
- Open source repo: https://github.com/ssherman/the-greatest/
- Discord: https://discord.com/invite/8JE9fpMtZp

---

## Interfaces & Contracts

### Endpoints

| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | `/rankings` (music domain) | Music rankings explanation page | none | public |
| GET | `/rankings` (games domain) | Games rankings explanation page | none | public |

> Source of truth: `config/routes.rb`

### Behaviors

#### Music Homepage (`music/default#index`)
- **Change**: Replace the current hero section copy with a friendlier "about" paragraph
- **Keep**: Links to Albums, Songs, Artists remain as CTA buttons
- **Add**: Short Discord invite sentence inside the hero section (not in its own container)
- **Keep**: Featured albums grid and featured songs table below hero (unchanged)

**Proposed hero copy (music):**

> Ever wonder which albums and songs truly stand the test of time? We built The Greatest Music to answer that. Our algorithm combines hundreds of "best of" lists -- from critics, musicians, and fans around the world -- into one comprehensive ranking. Instead of trusting a single opinion, we look at the bigger picture: where do all these lists agree, and where do they surprise us? Check out the rankings below, or learn [how it all works](/rankings).

**Discord line (below the CTA buttons, inside hero):**

> Got opinions? Join the conversation on [Discord](https://discord.com/invite/8JE9fpMtZp).

#### Games Homepage (`games/ranked_items#index`)
- **Change**: Show a hero/about section at the top of the page **only when there are no filters, no page params, and no ranking_configuration_id param** (i.e., only on the bare root page)
- **Keep**: Everything else about the ranked items page unchanged

**Condition for showing hero** (in controller or view):
```ruby
# reference only
def show_hero?
  !params[:year].present? && !params[:page].present? && !params[:ranking_configuration_id].present?
end
```

**Proposed hero copy (games):**

> What makes a video game truly great? We set out to find a definitive answer. The Greatest Games aggregates hundreds of "best of" lists from critics, developers, and players worldwide, then runs them through a ranking algorithm that weighs each list's quality, credibility, and scope. The result is a consensus ranking you can actually trust. Curious how it works? Check out our [rankings page](/rankings).

**Discord line (below hero text):**

> Want to talk games? Join us on [Discord](https://discord.com/invite/8JE9fpMtZp).

#### Rankings Page (both domains)

Each domain gets its own rankings page at `/rankings`, rendered by its respective `DefaultController#rankings` action.

**Layout: 2-column on desktop, stacked on mobile**

```
Desktop:
+----------------------------------+------------------+
| Main content (rankings explain)  | Sidebar          |
|                                  |  - Discord card  |
|                                  |  - Open Source   |
+----------------------------------+------------------+

Mobile (stacked, sidebar cards FIRST):
+----------------------------------+
| Discord card                     |
| Open Source card                 |
+----------------------------------+
| Main content (rankings explain)  |
+----------------------------------+
```

**Main content sections:**

1. **How Our Rankings Work** (heading)

   Introductory paragraph:
   > Most "best of" aggregation sites just count how many lists something appears on and call it a day. We think that misses the point. Not all lists are created equal -- a carefully curated ranking by music critics carries different weight than a fan poll on a random forum. Our algorithm takes that into account.

2. **The Algorithm** (subheading)

   > Every list in our system starts with a base quality score. From there, we evaluate each list across several dimensions -- who voted, how many people voted, what the list covers, and whether it focuses on a specific niche or tries to be comprehensive. Lists that are more credible and broader in scope naturally carry more weight in the final rankings.

   > Items that appear on multiple high-quality lists rise to the top. But we also give credit to items that land on a single exceptional list -- consensus matters, but so does expert recognition.

3. **What We Look At** (subheading)

   > Here are some of the factors our algorithm considers when evaluating a list:

   **Dynamic list of active penalties** -- queried from the ranking configuration's penalty applications joined to their penalties, showing only the `penalty.name` values that are actually in use. Grouped into two sections:

   - **List Quality Signals** -- static penalties (the ones attached to individual lists)
   - **Automatic Adjustments** -- dynamic penalties (triggered by list attributes like voter count, geographic scope, time coverage, etc.)

   Display as simple bullet lists. No numbers, no percentages.

4. **Solving for Recency Bias** (subheading)

5. **By the Numbers** (subheading)

   Dynamic stats pulled from the database:
   - Number of active lists in the primary ranking configuration
   - Total number of ranked items
   - Median number of items per list (using `List.median_list_count`)

   Format as a simple stats row (e.g., 3 cards or a horizontal stat strip).

6. **Open Source** (subheading)

**Sidebar cards:**

- **Discord card**: "Join the Community" heading, short sentence, link to Discord invite
- **Open Source card**: "Open Source" heading, brief text, links to both repos

### Schemas (JSON)

N/A -- no API endpoints, these are server-rendered pages.

### Non-Functionals
- All new pages cached via `Cacheable` concern (`cache_for_index_page` for rankings)
- No N+1: penalty queries should be eager-loaded
- Pages should work on mobile (responsive 2-col -> 1-col)
- SEO: `content_for :page_title` and `content_for :meta_description` set on all new pages

---

## Acceptance Criteria

### Music Homepage
- [x] Hero section displays new friendly copy instead of old generic text
- [x] Hero still has CTA buttons linking to Albums, Songs, Artists
- [x] Discord invite sentence appears in the hero section
- [x] Link to `/rankings` appears in the hero copy
- [x] Featured albums and songs sections remain unchanged
- [x] Page is cached (existing behavior, no regression)

### Games Homepage
- [x] Hero/about section appears when visiting the bare root URL (no filters, no page param, no RC param)
- [x] Hero does NOT appear when any year filter is applied
- [x] Hero does NOT appear when `page` param is present (pagination)
- [x] Hero does NOT appear when `ranking_configuration_id` param is present
- [x] Discord invite sentence appears in the hero section
- [x] Link to `/rankings` appears in the hero copy
- [x] Ranked items grid and pagination remain unchanged
- [x] Page is cached (existing behavior, no regression)

### Rankings Page (Music)
- [x] Accessible at `/rankings` on the music domain
- [x] Displays all content sections: intro, algorithm, penalties, recency bias, stats, open source
- [x] Penalty list is dynamically queried from the active primary ranking configuration
- [x] Static penalties shown under "List Quality Signals"
- [x] Dynamic penalties shown under "Automatic Adjustments"
- [x] No penalty percentages or numbers are shown -- names only
- [x] Stats section shows dynamic counts (active lists, ranked items, median list count)
- [x] 2-column layout on desktop with Discord + Open Source sidebar
- [x] Single column on mobile with sidebar cards stacked above main content
- [x] Discord card links to https://discord.com/invite/8JE9fpMtZp
- [x] Open source card links to both GitHub repos
- [x] Page is cached via `Cacheable` concern
- [x] `content_for :page_title` and `content_for :meta_description` are set

### Rankings Page (Games)
- [x] Same as Music rankings page but on the games domain
- [x] Uses the games primary ranking configuration for penalties and stats
- [x] Uses the games layout and theme

### Tests
- [x] Integration test: music homepage renders new hero copy
- [x] Integration test: music `/rankings` returns 200
- [x] Integration test: games root (no params) renders hero section
- [x] Integration test: games root with year filter does NOT render hero section
- [x] Integration test: games root with page param does NOT render hero section
- [x] Integration test: games `/rankings` returns 200
- [x] Rankings pages display penalty names from the active configuration
- [x] E2E test: music `/rankings` loads with all sections
- [x] E2E test: games `/rankings` loads with all sections

### Golden Examples

```text
Input: GET / on music domain (no params)
Output: Hero with "Ever wonder which albums and songs truly stand the test of time?..." copy,
        CTA buttons for Albums/Songs/Artists, Discord line, featured albums, featured songs

Input: GET / on games domain (no params)
Output: Hero with "What makes a video game truly great?..." copy, Discord line,
        followed by ranked games grid

Input: GET /video-games/1990s on games domain
Output: No hero section. Just the filtered ranked games grid with decade tabs.

Input: GET /rankings on music domain
Output: Full rankings explanation page with dynamic penalty list and stats from
        both Music::Albums::RankingConfiguration and Music::Songs::RankingConfiguration
        (penalties deduplicated by name across both configs)
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.
- Use existing `Cacheable` concern for caching -- do not invent new caching.
- Copy should feel human and friendly, not corporate or AI-generated.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests for the Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> confirm controller/view patterns for new actions
2) codebase-analyzer -> verify penalty query data flow
3) UI Engineer -> build responsive 2-column rankings layout
4) technical-writer -> update docs and cross-refs

### Test Seed / Fixtures
- Existing fixtures for `ranking_configurations`, `penalties`, `penalty_applications`, `lists`, `list_penalties` sufficed
- No new fixtures were needed

---

## Implementation Notes (living)

### Approach
- Added `rankings` action to `Music::DefaultController` and `Games::DefaultController`
- Added routes for `/rankings` in both domain constraints
- For games hero: added `@show_hero` flag in `Games::RankedItemsController#index` based on params
- Music penalties: combined from both `Music::Albums::RankingConfiguration.default_primary` and `Music::Songs::RankingConfiguration.default_primary`, deduplicated by `name`
- Music stats: active lists and ranked items summed across both album and song RCs; median uses album lists
- Games penalties/stats: loaded from `Games::RankingConfiguration.default_primary`
- Rankings views are separate per-domain for easy customization
- Used `flex-col-reverse` for mobile-first sidebar stacking on rankings pages

### Key Files Touched (paths only)
- `config/routes.rb`
- `app/controllers/music/default_controller.rb`
- `app/controllers/games/default_controller.rb`
- `app/controllers/games/ranked_items_controller.rb`
- `app/views/music/default/index.html.erb`
- `app/views/music/default/rankings.html.erb` (new)
- `app/views/games/default/rankings.html.erb` (new)
- `app/views/games/ranked_items/index.html.erb`
- `app/views/layouts/music/application.html.erb`
- `app/views/layouts/games/application.html.erb`
- `app/views/music/searches/index.html.erb`
- `app/views/games/searches/index.html.erb`
- `test/controllers/music/default_controller_test.rb`
- `test/controllers/games/default_controller_test.rb`
- `test/controllers/games/ranked_items_controller_test.rb`
- `e2e/pages/music/home-page.ts`
- `e2e/tests/music/public/rankings.spec.ts` (new)
- `e2e/tests/games/public/rankings.spec.ts` (new)

### Challenges & Resolutions
- Games root routes to `ranked_items#index`, not `default#index`. The `/rankings` route goes to `games/default#rankings` while the root stays at `games/ranked_items#index`.
- Penalty query: combined penalties from both music album and song RCs, deduplicated by `name`, split by `dynamic?` vs `static?`.
- Hero styling: replaced hardcoded gradient colors (purple-to-blue, green-to-cyan) with DaisyUI theme-aware `bg-base-200` cards for consistency with each domain's theme.
- Mobile navbar: search input was overlapping the site logo on small screens. Fixed by showing a search icon link on mobile that navigates to `/search`, which now has its own search input form.

### Deviations From Plan
- Removed `<h1>` heading from hero sections (redundant with site branding in navbar)
- Used theme-aware `bg-base-200` cards instead of hardcoded gradient backgrounds for heroes
- Hero text is left-aligned within a centered 75%-width container (not center-aligned text)
- Games page heading and filter tabs were centered for visual consistency with the hero
- Added search input to `/search` pages for mobile UX (not in original spec)
- Mobile navbar search replaced with icon link to search page (not in original spec)

## Acceptance Results
- Date: 2026-03-06
- Verifier: Manual review + automated tests
- All 4,035 unit/integration tests pass (0 failures, 0 errors)
- All 16 E2E tests pass (including 10 new rankings page tests)

## Future Improvements
- Add rankings page to movies domain when it launches
- Consider a shared ViewComponent for the rankings content if all domains converge
- Add "suggest a list" CTA to the rankings page
- A/B test hero copy

## Related PRs
- #...

## Documentation Updated
- [x] Spec file completed and moved to `docs/specs/completed/`
