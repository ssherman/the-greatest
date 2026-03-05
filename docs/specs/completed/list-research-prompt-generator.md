# List Research Prompt Generator

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-03-04
- **Started**: 2026-03-04
- **Completed**: 2026-03-04
- **Developer**: Claude

## Overview
Add a "Copy Research Prompt" button to the admin list show page that opens a modal with a pre-filled AI research prompt for the current list, and a clipboard copy button. The prompt templates are domain-specific (games, albums, songs) and pull data from the list's existing fields (name, url, source, year_published). Additionally, store the prompt templates as markdown files in `web-app/docs/ai/lists/prompts/` for reference and reuse outside the app.

**Non-goals**: Dynamic/configurable prompt editing in-app; prompt templates stored in the database.

## Context & Links
- Related: Admin list management feature, AI-powered list import wizard
- Source files:
  - `web-app/app/components/admin/lists/show_component.rb`
  - `web-app/app/components/admin/lists/show_component.html.erb`
  - `web-app/app/controllers/admin/lists_base_controller.rb`
  - `web-app/app/models/list.rb`
- Domain list types: `Games::List`, `Music::Albums::List`, `Music::Songs::List`

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes required. Prompts are hardcoded templates rendered with list data.

### Endpoints
No new endpoints. This is a client-side feature using a Stimulus controller for modal display and clipboard copy.

### Behaviors (pre/postconditions)

**Button placement**: A "Research Prompt" button appears in the action bar on the admin list show page (next to Launch Wizard, Edit, Delete).

**Modal contents**:
- Read-only textarea containing the fully interpolated research prompt
- "Copy to Clipboard" button
- Visual feedback on successful copy (e.g., button text changes to "Copied!" briefly)

**Prompt interpolation**:
- `<title>` -> `list.name`
- `<url>` -> `list.url` (or "N/A" if blank)
- `<source>` -> `list.source` (or "N/A" if blank)
- `<year_published>` -> `list.year_published` (or "Unknown" if blank)
- Domain-specific noun substitution (see templates below)

**Domain-specific prompt templates**:

Each domain has its own prompt with the correct noun (games/albums/songs) and website name:

| Domain | Noun (singular/plural) | Website Name |
|---|---|---|
| `Games::List` | game / games | The Greatest Games |
| `Music::Albums::List` | album / albums | The Greatest Albums |
| `Music::Songs::List` | song / songs | The Greatest Songs |

**Edge cases**:
- If `url` is blank, interpolate as "N/A"
- If `source` is blank, interpolate as "N/A"
- If `year_published` is nil, interpolate as "Unknown"

**Research prompt should guide the AI to populate these list fields**:

The prompt must explain the following fields so the AI researcher understands what data we need and why. The prompt output should help the admin fill in these fields accurately.

| Field | Type | Description |
|---|---|---|
| `number_of_voters` | integer | **The most important field.** The number of people who contributed to selecting/voting on items in the list. Estimates should be **conservative** (err on the low side). If a range is plausible, pick the lower-middle. If truly unknowable, leave blank rather than guess wildly. |
| `voter_count_estimated` | boolean | True when `number_of_voters` is an estimate rather than a confirmed count. Should be set whenever the exact number isn't explicitly stated by the source. |
| `voter_count_unknown` | boolean | True when the number of voters/contributors genuinely cannot be determined or reasonably estimated. Use this when there's no information at all about who or how many people contributed. |
| `voter_names_unknown` | boolean | True when the identities of the contributors are not publicly listed or discoverable. A list might have a known voter count but unnamed voters (e.g., "voted on by 50 critics" with no names). |
| `high_quality_source` | boolean | True when the list comes from a well-established, reputable, and authoritative source (e.g., major publications, respected industry organizations, long-running institutions). |
| `yearly_award` | boolean | True when the list is published annually as a recurring award or ranking (e.g., "Best of 2024", Grammy nominees). |
| `category_specific` | boolean | True when the list is limited to a specific sub-category or genre within the domain (e.g., "Best RPGs" rather than "Best Games", "Best Jazz Albums" rather than "Best Albums"). |
| `location_specific` | boolean | True when the list is scoped to a specific geographic region or country (e.g., "Best British Albums", "Top Japanese Games"). |
| `creator_specific` | boolean | True when the list focuses on works by a specific creator or group (e.g., "Best Beatles Albums", "Top Miyamoto Games"). |

The prompt should emphasize:
1. **`number_of_voters` is the highest priority** - we need this to weight lists in our ranking algorithm. A list voted on by 1,000 critics carries more weight than one person's opinion.
2. **Conservative estimation** - when unsure, estimate low. It's better to undercount than overcount contributors.
3. **Distinguish between known vs estimated vs unknown** - the three voter fields work together to capture confidence level.
4. **Description should be written for website readers** - it should summarize the list's methodology, purpose, and credibility in 2-4 sentences.

### Non-Functionals
- No server round-trip for clipboard copy (use Clipboard API)
- Works on all modern browsers (Clipboard API is widely supported)

## Acceptance Criteria
- [ ] "Research Prompt" button visible on admin list show page for games, albums, and songs domains
- [ ] Clicking button opens a DaisyUI modal with the interpolated prompt text
- [ ] Prompt text correctly substitutes list name, url, source, year_published
- [ ] Prompt text uses domain-appropriate nouns and website name
- [ ] "Copy to Clipboard" button copies prompt text to clipboard
- [ ] Visual feedback shown after copying (button text change or toast)
- [ ] Markdown prompt template files created in `web-app/docs/ai/lists/prompts/` for games, albums, songs
- [ ] ViewComponent test covers prompt generation for each domain
- [ ] Stimulus controller test covers clipboard copy behavior

### Golden Examples

**Input**: Games::List with name="IGN Top 100", url="https://ign.com/top100", source="IGN", year_published=2024

**Output prompt**:
```text
I would like you to research the following Video Games List:

title: IGN Top 100
url: https://ign.com/top100
source: IGN
Year Published: 2024

What I am looking for:

1. **Number of Contributors (MOST IMPORTANT)**: How many people contributed to picking out the games on the list? This is critical for our ranking algorithm - lists with more contributors carry more weight. Be conservative in your estimate (err on the low side). If a range seems plausible, go with the lower-middle.

2. **Contributor Details**:
   - Who contributed to picking out the games on the list?
   - Are the names of the people who contributed publicly listed?
   - Can the number of contributors be estimated? Do we know for sure there's more than one?

3. **Confidence Level**: For each answer, indicate whether the information is:
   - Confirmed (explicitly stated by the source)
   - Estimated (reasonably inferred but not stated)
   - Unknown (cannot be determined)

4. **Source Quality**: Is this source well-established and reputable? Is it a major publication, respected industry organization, or long-running institution?

5. **List Characteristics**:
   - Is this a yearly/recurring award?
   - Is it limited to a specific genre or category of games?
   - Is it specific to a geographic region?
   - Is it focused on a specific creator or company?

6. **Summary/Description**: Write a 2-4 sentence description of this list for readers of my website The Greatest Games. This description should summarize the criteria for the list, the purpose of the list, the methodology, and the credibility of the source.
```

**Input**: Music::Albums::List with name="Rolling Stone 500", url="", source="Rolling Stone", year_published=nil

**Output prompt** (note url="N/A", year="Unknown", nouns="albums", site="The Greatest Albums"):
```text
I would like you to research the following Albums List:

title: Rolling Stone 500
url: N/A
source: Rolling Stone
Year Published: Unknown

What I am looking for:

1. **Number of Contributors (MOST IMPORTANT)**: How many people contributed to picking out the albums on the list? This is critical for our ranking algorithm - lists with more contributors carry more weight. Be conservative in your estimate (err on the low side). If a range seems plausible, go with the lower-middle.

2. **Contributor Details**:
   - Who contributed to picking out the albums on the list?
   - Are the names of the people who contributed publicly listed?
   - Can the number of contributors be estimated? Do we know for sure there's more than one?

3. **Confidence Level**: For each answer, indicate whether the information is:
   - Confirmed (explicitly stated by the source)
   - Estimated (reasonably inferred but not stated)
   - Unknown (cannot be determined)

4. **Source Quality**: Is this source well-established and reputable? Is it a major publication, respected industry organization, or long-running institution?

5. **List Characteristics**:
   - Is this a yearly/recurring award?
   - Is it limited to a specific genre or category of albums?
   - Is it specific to a geographic region?
   - Is it focused on a specific artist or group?

6. **Summary/Description**: Write a 2-4 sentence description of this list for readers of my website The Greatest Albums. This description should summarize the criteria for the list, the purpose of the list, the methodology, and the credibility of the source.
```

### Optional Reference Snippet (<=40 lines, non-authoritative)
```ruby
# reference only - domain config mapping
DOMAIN_PROMPT_CONFIG = {
  "Games::List" => {
    noun_plural: "games", list_type_label: "Video Games",
    site_name: "The Greatest Games", creator_term: "creator or company"
  },
  "Music::Albums::List" => {
    noun_plural: "albums", list_type_label: "Albums",
    site_name: "The Greatest Albums", creator_term: "artist or group"
  },
  "Music::Songs::List" => {
    noun_plural: "songs", list_type_label: "Songs",
    site_name: "The Greatest Songs", creator_term: "artist or group"
  }
}.freeze
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Use existing DaisyUI modal pattern (see `add_item_to_list_modal_component` and `attach_penalty_modal_component` for reference).
- Use existing Stimulus controller patterns for clipboard functionality.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> collect modal component patterns from existing admin modals
2) codebase-analyzer -> verify show_component integration and domain_config flow
3) technical-writer -> create markdown prompt template files and update docs

### Test Seed / Fixtures
- Use existing list fixtures for games, albums, and songs domains
- Ensure fixtures have name, url, source, year_published populated for happy path tests

### Implementation Guidance

**New files to create**:
1. `web-app/app/components/admin/lists/research_prompt_modal_component.rb`
2. `web-app/app/components/admin/lists/research_prompt_modal_component.html.erb`
3. `web-app/app/javascript/controllers/clipboard_copy_controller.js` (Stimulus controller)
4. `web-app/docs/ai/lists/prompts/games-research-prompt.md`
5. `web-app/docs/ai/lists/prompts/albums-research-prompt.md`
6. `web-app/docs/ai/lists/prompts/songs-research-prompt.md`

**Files to modify**:
1. `web-app/app/components/admin/lists/show_component.html.erb` - Add button + render modal
2. Stimulus controller manifest (if not auto-loaded)

**Testing files to create**:
1. `web-app/test/components/admin/lists/research_prompt_modal_component_test.rb`

---

## Implementation Notes (living)
- Approach taken: ViewComponent with hardcoded DOMAIN_CONFIG hash for prompt generation, Stimulus controller for clipboard copy
- Important decisions: Used `btn-secondary btn-outline` for button style to match action bar. Component uses `render?` to hide for unsupported domains (books, movies).

### Key Files Touched (paths only)
- `app/components/admin/lists/research_prompt_modal_component.rb`
- `app/components/admin/lists/research_prompt_modal_component.html.erb`
- `app/components/admin/lists/show_component.html.erb`
- `app/javascript/controllers/clipboard_copy_controller.js`
- `app/javascript/controllers/index.js`
- `web-app/docs/ai/lists/prompts/games-research-prompt.md`
- `web-app/docs/ai/lists/prompts/albums-research-prompt.md`
- `web-app/docs/ai/lists/prompts/songs-research-prompt.md`
- `test/components/admin/lists/research_prompt_modal_component_test.rb`

### Challenges & Resolutions
- None

### Deviations From Plan
- None

## Acceptance Results
- 2026-03-04: 8 tests passing (278 total admin component tests pass). Verified on games, albums, and songs list show pages.

## Future Improvements
- Make prompt templates editable in admin settings
- Add prompts for movies and books domains
- Store generated prompts / AI responses alongside lists (link to AiChat)
- Add a "Research with AI" button that sends the prompt directly to an AI service

## Related PRs
-

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs
