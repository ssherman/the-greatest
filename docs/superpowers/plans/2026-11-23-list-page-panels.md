# List page panels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the top sections of a books list page in visible panels, and keep the score visible while its arithmetic opens on click.

**Architecture:** `Lists::WeightBreakdownComponent` becomes the score panel, with its rows inside a native `<details>` styled as a daisyUI collapse. Books and games both render it. The books show page then becomes a 2/3 + 1/3 grid around it.

**Tech Stack:** Rails 8, ViewComponent, Tailwind v4.3.5, daisyUI 5.8.2, Minitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-23-list-page-panels-design.md`

## Global Constraints

- Work only in `/home/shane/dev/the-greatest/.claude/worktrees/list-page-panels`. Run Rails and yarn from its `web-app/`.
- Panel classes, exactly: `card bg-base-100 border border-base-300 shadow-sm`.
- Copy, exactly: `How good is this list?`, `See how this was worked out`, `Nothing lowers it`, `1 thing lowers it`, `N things lower it`.
- No new JavaScript. No daisyUI v4 classes (list in `AGENTS.md`).
- Every panel has a border. Nothing may rely on colour alone.
- Headings stay outside `<summary>`.
- Music list pages are not touched. Weight calculation and penalty names are not touched.
- End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not push.
- **Closed `<details>` and Capybara:** its content counts as hidden. `assert_text "row"` fails there, and `assert_no_text "row"` **passes for the wrong reason**. Use the `:all` form for every check on a row.

## Review Focus

1. A source with no spaces, on a phone: the pill wraps and the page does not scroll sideways at 320px (Task 2).
2. Details with no `penalties` key, or a quality bonus and no penalties: "Nothing lowers it", no bar, no error (Task 1).
3. Keyboard only: focus the bar, press Enter, the rows appear (Task 1).
4. A list with exactly one voter reads "1 voter" (Task 2).
5. A description with line breaks keeps them (Task 2).

## File Structure

| File | Change |
|---|---|
| `web-app/app/components/lists/weight_breakdown_component.{rb,html.erb}` | Score panel with click-to-open rows |
| `web-app/app/views/games/lists/show.html.erb` | Wrapper around the panel |
| `web-app/app/views/books/lists/show.html.erb` | Panels and two-column layout |
| `web-app/test/components/lists/weight_breakdown_component_test.rb` | Updated and new tests |
| `web-app/e2e/tests/books/lists.spec.ts`, `web-app/e2e/tests/games/public/lists.spec.ts` | Score visible, rows open on click |
| `web-app/e2e/tests/books/admin/lists.spec.ts` | Review Focus 1, 4, 5 on the existing voters test |

---

### Task 1: Score panel (books and games)

**Files:**
- Modify: `web-app/app/components/lists/weight_breakdown_component.rb`, `.html.erb`
- Modify: `web-app/app/views/games/lists/show.html.erb:42`
- Test: `web-app/test/components/lists/weight_breakdown_component_test.rb`
- Test: `web-app/e2e/tests/books/lists.spec.ts`, `web-app/e2e/tests/games/public/lists.spec.ts`

**Interfaces:**
- Consumes: nothing new. `Lists::WeightBreakdownComponent.new(ranked_list:)` keeps its signature.
- Produces: a root `<div>` carrying the panel classes and filling its container's width. Task 2 places it in a grid column.

- [ ] **Step 1: Prepare the worktree.** The harness did not copy the gitignored files. From the worktree root, copy `.env`, `web-app/.env`, `web-app/config/master.key` and `web-app/e2e/.env` from `/home/shane/dev/the-greatest`, symlink `web-app/node_modules` to the main checkout's, then in `web-app/` run `yarn build:all && bin/rails db:test:prepare`.

  Check: `bin/rails test test/components/lists test/controllers/books/lists_controller_test.rb` is green, and `git status --short` shows nothing new.

- [ ] **Step 2: Move the existing row assertions to `:all`.** In the component test, change every `assert_text` / `assert_no_text` on a row (penalty names, percentages, "Base weight", "Total penalty", "High quality source bonus", "Penalty capped at", "Raised to the minimum weight", "Final weight") to `assert_text :all, ...` / `assert_no_text :all, ...`. Leave the two fallback-message tests as they are. In the ordering test use:

```ruby
penalty_names = page.all("dt", visible: :all).map { |dt| dt.text(:all) } - ["Base weight", "Total penalty", "Final weight"]
```

  In "renders no penalty section when the list has none", replace the body after `render_inline` with the assertions of the `no penalties` test in Step 3, and rename it to that test's name.

- [ ] **Step 3: Write the failing tests.**

```ruby
test "shows the score and the count while the rows stay closed" do
  render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(full_details)))

  assert_text "Weight 15%"
  assert_text "3 things lower it"
  assert_selector "details.collapse:not([open]) > summary", text: "See how this was worked out"
  assert_no_text "Base weight"
  assert_text :all, "Base weight"
end

test "uses the singular for one penalty" do
  details = full_details.merge("penalties" => [{"penalty_name" => "Voters: Unknown Names", "value" => 5.0}])
  render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(details)))

  assert_text "1 thing lowers it"
end

test "no penalties: says nothing lowers it and has nothing to open" do
  [full_details.merge("penalties" => []),
    full_details.except("penalties"),
    full_details(quality_bonus_applied: true).merge("penalties" => [])].each do |details|
    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(details)))

    assert_text "Nothing lowers it"
    assert_no_selector "details"
  end
end

test "the fallbacks have nothing to open" do
  [nil, ranked_list_with(nil)].each do |ranked_list|
    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list))

    assert_text "How good is this list?"
    assert_no_selector "details"
  end
end

test "the heading is not inside the summary" do
  render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(full_details)))

  assert_selector "h2", text: "How good is this list?"
  assert_no_selector "summary h2", visible: :all
end
```

- [ ] **Step 4: Run them.** `bin/rails test test/components/lists/weight_breakdown_component_test.rb`. Expected: FAIL on the new count, `details` and wording tests. The fallback and heading tests pass already.

- [ ] **Step 5: Implement.** In the component class add one private method, `penalty_count_line -> String`, returning the three wordings. In the template:
  - Root: panel classes. Then `card-body`, the `h2.card-title`, and both fallbacks unchanged.
  - Score line `text-3xl font-semibold`, keeping the text `Weight N%`. Count line `text-base text-base-content/80`.
  - Only when `penalties.any?`: `<details class="collapse collapse-arrow border border-base-300 bg-base-200 mt-2">`, with `<summary class="collapse-title font-semibold">`, then `<div class="collapse-content">`.
  - Inside, one `<dl class="text-sm divide-y divide-base-300 max-w-2xl">`. Row: `flex justify-between gap-6 py-2`. `dt`: `min-w-0 [overflow-wrap:anywhere]`. `dd`: `whitespace-nowrap tabular-nums`.
  - Row order: base weight, penalties, total penalty, then the bonus, cap and floor rows under today's conditions, then final weight. Base, total and final are `font-semibold`, and the bonus row keeps `text-success`.
  - Drop the "What lowers this list's weight" subheading.

- [ ] **Step 6: Wrap it on games.** In `games/lists/show.html.erb`, put the render call inside `<div class="max-w-2xl mb-6">`.

- [ ] **Step 7: Run.** `bin/rails test test/components/lists test/controllers/games test/controllers/books/lists_controller_test.rb && bundle exec standardrb`. Expected: green, no offenses.

- [ ] **Step 8: Update E2E.** Replace the "Base weight" assertion in both specs with the block below. It opens by keyboard in books and by click in games, so each path is covered once. The first card on the books index is the heaviest list, which may have no penalties, so the books test must first pick a list that has the bar: follow the loop shape of `openPopulatedList` in the games spec, stopping at the first list where the bar is visible. If no list has one, throw.

```ts
const bar = page.getByText('See how this was worked out');
await expect(page.getByText(/^Weight -?[\d.]+%$/)).toBeVisible();
await expect(page.getByText('Base weight')).toBeHidden();
await bar.focus();                 // games: await bar.click();
await page.keyboard.press('Enter'); // games: omit
await expect(page.getByText('Base weight')).toBeVisible();
```

  Keep the existing `.card h2 a` book-grid assertion in the books test. In games, `openPopulatedList` may land on a list with no bar, so there also require the bar.

- [ ] **Step 9: Commit.** `git commit -m "Lists: score panel keeps the weight visible and opens the arithmetic on click"`

---

### Task 2: Books list page panels and layout

**Files:**
- Modify: `web-app/app/views/books/lists/show.html.erb:6-49`
- Test: `web-app/e2e/tests/books/admin/lists.spec.ts` (the "records who voted" test)

**Interfaces:**
- Consumes: the component from Task 1, which fills the width of its container.
- Produces: nothing later tasks use. `data-testid="list-voter-details"` must keep working.

- [ ] **Step 1: Extend the E2E test first.** In "records who voted and shows it on the admin and public list pages", also fill these before submitting: `books_list[source]` with `"x".repeat(88)`, `books_list[number_of_voters]` with `1`, and `books_list[description]` with `First paragraph.\n\nSecond paragraph.`. After the existing public-page assertions, add:

```ts
await expect(page.getByText('1 voter', { exact: true })).toBeVisible();
expect(await page.getByText('First paragraph.').innerText()).toMatch(/First paragraph\.\s*\n+\s*Second paragraph\./);
await page.setViewportSize({ width: 320, height: 800 });
expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(320);
await page.setViewportSize({ width: 1280, height: 720 });
```

- [ ] **Step 2: Build the layout** in `books/lists/show.html.erb`. The grid of books, pagination and empty state do not change.
  - Wrapper: `grid gap-6 lg:grid-cols-3 items-start`. Left: `min-w-0 space-y-6 lg:col-span-2`. Right: `min-w-0`, holding only the component. DOM order is header, who voted, score.
  - Header panel: `card-body gap-4 text-base` with the h1, facts, description and button, in that order. Keep the button's `rel`, `target` and classes.
  - Facts: a `<ul class="flex flex-wrap gap-2">` of `<li class="badge badge-lg h-auto py-1 max-w-full bg-base-200 border-base-300">`, with the text in one inner `<span class="min-w-0 whitespace-normal [overflow-wrap:anywhere]">`, because the badge is `inline-flex`. Same four facts and conditions as today.
  - Voters: `pluralize(number_with_delimiter(@list.number_of_voters), "voter")`.
  - Description and voter prose: `max-w-[68ch] text-base leading-relaxed text-base-content/80 whitespace-pre-line [overflow-wrap:anywhere]`.
  - Who voted: `<section>` with the panel classes, the existing `data-testid`, `h2.card-title`, and today's 600-character rule. Its bar uses Task 1's collapse classes. The section is absent with no voter details.
  - `whitespace-pre-line` renders template newlines too, so keep each `<p>` and its output tag on one line.

- [ ] **Step 3: Run Ruby tests.** `bin/rails test && bundle exec standardrb`. Expected: green, with no warnings beyond the two known sources in `AGENTS.md`.

- [ ] **Step 4: Run E2E.** Check port 3000 first with the command in `AGENTS.md`. If another checkout holds it, stop and tell Shane. Otherwise `yarn build:all`, then start `bin/rails server`, then:
  `yarn test:e2e e2e/tests/books/lists.spec.ts e2e/tests/books/admin/lists.spec.ts e2e/tests/games/public/lists.spec.ts`
  Expected: all pass. Then prove the new checks can fail: temporarily remove `whitespace-normal [overflow-wrap:anywhere]` from the pill span and confirm the 320px check goes red, then restore it.

- [ ] **Step 5: Look at it.** Screenshot books and games list pages at 320, 390, 1024 and 2000px, closed and open. On books use one list with a description only, and one with voter details. Dev has no voter details, so use the E2E-created list or a temporary one. Check that every panel edge is visible (games is dark), labels and numbers sit close together, and nothing scrolls sideways. Compare books against layout A. Report any difference from the spec.

- [ ] **Step 6: Commit.** `git commit -m "Books: list page sections in their own panels"`
