# Books Linen Background & Owned Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the books site a warm paper-like page background with white panels, replace the borrowed daisyUI `cmyk` theme with an owned `books` theme, and retune the palette so it is legible to a red-green colorblind maintainer.

**Architecture:** Two changes, in order. First define a `books` daisyUI theme carrying the full token set and point the two `data-theme` references at it. Second, move every surface down one rung of the existing three-step base ramp so the page becomes linen, chrome bands become the deeper warm step, and panels stay white. No layout, structural, or component-API changes.

**Tech Stack:** Tailwind CSS 4, daisyUI 5 (`^5.0.43`), Rails 8 ERB views + ViewComponents, Minitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-02-books-linen-background-and-theme-design.md`

## Global Constraints

- Run **all** Rails and yarn commands from `web-app/`. Docs live in `docs/` at the **project root**.
- Lint with `bundle exec standardrb`. **Not** `bin/rubocop` — it is omakase and enforces a conflicting style.
- **Do not run brakeman.** The owner does not use it.
- **No code comments** unless explicitly asked. The CSS token block is the one exception: it carries the section comments shown below because they are part of the approved spec.
- `web-app/app/assets/builds/` is **gitignored**. Never `git add` built CSS. The deploy builds it.
- **Never run destructive database commands against development.** No `db:drop`, `db:reset`, `db:schema:load`, `create_fixtures`, or bulk `delete_all`/`destroy_all`. The books data exists only in development and takes hours to rebuild.
- **Controller and integration tests assert behavior, never HTML/CSS/copy.** Do **not** add any test asserting a CSS class such as `bg-base-200`. This plan deliberately contains no such test; the surface changes are verified by building the CSS, running the existing suite for regressions, and a manual pass.
- Scope is **books only**. Do not touch the music or games stylesheets, layouts, or views.

---

### Task 1: Define and wire the `books` theme

Replaces the borrowed `cmyk` theme with an owned `books` theme carrying the full token set. After this task the palette is navy/oxblood/gold and the semantic colors sit on the CVD-safe ladder, but the page is still white — the surface change lands in Task 2.

**Files:**
- Modify: `web-app/app/assets/stylesheets/books/application.css:9-11`
- Modify: `web-app/app/views/layouts/books/application.html.erb:2`
- Modify: `web-app/app/lib/admin/domain_nav.rb:69`
- Test: `web-app/test/lib/admin/domain_nav_test.rb:19`

**Interfaces:**
- Consumes: nothing — this is the first task.
- Produces: a daisyUI theme named `books` that is the default for the books stylesheet, exposing the standard daisyUI token names (`--color-base-100`, `--color-base-200`, `--color-base-300`, `--color-primary`, …). Task 2 relies on `base-100` / `base-200` / `base-300` having the values set here. `Admin::DomainNav.chrome_for(:books)[:theme]` returns the string `"books"`.

- [ ] **Step 1: Update the test assertion so it fails**

In `web-app/test/lib/admin/domain_nav_test.rb`, change line 19:

```ruby
      books = Admin::DomainNav.chrome_for(:books)
      assert_equal "books", books[:theme]
      assert_equal "books", books[:stylesheet]
      assert_equal "The Greatest Books", books[:title]
      assert_nil books[:favicon_dir]
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web-app && bin/rails test test/lib/admin/domain_nav_test.rb
```

Expected: FAIL — `Expected: "books"  Actual: "cmyk"`.

- [ ] **Step 3: Point the admin domain registry at the new theme**

In `web-app/app/lib/admin/domain_nav.rb`, inside the `books:` entry of `CONFIGS` (line 69), change the theme value:

```ruby
      books: {
        theme: "books",
        stylesheet: "books",
```

Leave every other key in that entry untouched.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web-app && bin/rails test test/lib/admin/domain_nav_test.rb
```

Expected: PASS — 2 runs, 0 failures, 0 errors.

- [ ] **Step 5: Point the public layout at the new theme**

In `web-app/app/views/layouts/books/application.html.erb`, line 2:

```erb
<html lang="en" data-theme="books">
```

- [ ] **Step 6: Replace the theme declaration in the books stylesheet**

In `web-app/app/assets/stylesheets/books/application.css`, replace this block:

```css
@plugin "daisyui" {
  themes: cmyk --default;
}
```

with:

```css
@plugin "daisyui" {
  themes: false;
}

@plugin "daisyui/theme" {
  name: "books";
  default: true;
  color-scheme: light;

  /* surfaces */
  --color-base-100: oklch(100% 0 0);
  --color-base-200: oklch(97.7% 0.009 85);
  --color-base-300: oklch(93.5% 0.013 83);
  --color-base-content: oklch(20% 0 0);

  /* brand */
  --color-primary: oklch(42% 0.10 250);
  --color-primary-content: oklch(98% 0 0);
  --color-secondary: oklch(38% 0.09 30);
  --color-secondary-content: oklch(97% 0.01 30);
  --color-accent: oklch(80% 0.12 88);
  --color-accent-content: oklch(24% 0.05 88);
  --color-neutral: oklch(21.778% 0 0);
  --color-neutral-content: oklch(84.355% 0 0);

  /* semantic — spaced on lightness for red-green CVD */
  --color-info: oklch(64% 0.11 245);
  --color-info-content: oklch(18% 0.03 245);
  --color-success: oklch(52% 0.15 310);
  --color-success-content: oklch(98% 0 0);
  --color-warning: oklch(68% 0.15 62);
  --color-warning-content: oklch(22% 0.05 62);
  --color-error: oklch(55% 0.20 28);
  --color-error-content: oklch(98% 0 0);

  /* geometry — carried over from cmyk unchanged */
  --radius-selector: 1rem;
  --radius-field: 0.5rem;
  --radius-box: 1rem;
  --size-selector: 0.25rem;
  --size-field: 0.25rem;
  --border: 1px;
  --depth: 0;
  --noise: 0;
}
```

Do not touch the `@import`, `@source`, or `@layer base` blocks. The Lora / Playfair Display font rules stay exactly as they are.

Two details that matter and are easy to get wrong:

- `themes: false` on the first block stops daisyUI emitting any built-in theme, so `books` is the only theme definition in the output rather than two competing on source order.
- `books` is **not** a built-in daisyUI theme name, so no merge with a built-in theme happens. Every token must be listed explicitly — that is deliberate, and it is why the block is long. (When the name *does* match a built-in, `daisyui/theme/index.js` merges over it; that is not the case here.)
- `color-scheme: light;` is an option key, not a CSS custom property, which is why it has no `--` prefix. daisyUI reads it as `themeTokens["color-scheme"]`. Without it the theme would fall back to `normal` and lose the light-mode form-control rendering that `cmyk` provided.

- [ ] **Step 7: Build the CSS and verify the theme landed**

```bash
cd web-app && yarn build:css:books
```

Expected: build succeeds with no errors.

```bash
cd web-app && grep -o 'data-theme="[a-z]*"' app/assets/builds/books.css | sort | uniq -c
```

Expected: exactly one distinct value, `data-theme="books"`. If `data-theme="cmyk"` still appears, the `themes: false` change did not take.

```bash
cd web-app && grep -c '97.7%' app/assets/builds/books.css
```

Expected: at least `1` — that is the linen `base-200` lightness, and no other token uses it. Match on `97.7%` alone rather than the full `oklch(...)` string, because the minifier rewrites numbers (`0.009` becomes `.009`) and an exact-string grep would give a false negative.

- [ ] **Step 8: Run the full suite and lint**

```bash
cd web-app && bin/rails test
```

Expected: 5240 runs, 0 failures, 0 errors, 0 skips. (Baseline recorded 5240 runs / 13936 assertions on this branch.)

```bash
cd web-app && bundle exec standardrb
```

Expected: no offenses.

- [ ] **Step 9: Commit**

```bash
git add web-app/app/assets/stylesheets/books/application.css \
        web-app/app/views/layouts/books/application.html.erb \
        web-app/app/lib/admin/domain_nav.rb \
        web-app/test/lib/admin/domain_nav_test.rb
git commit -m "Replace the borrowed cmyk theme with an owned books theme

Defines a daisyUI theme named books carrying the full token set, so the
books palette can no longer drift when daisyUI is upgraded.

The palette is built as a brightness ladder rather than a hue wheel.
Colors that collapse into the yellow-brown axis under red-green CVD
(secondary 38, error 55, warning 68, accent 80) are spaced 12-17
lightness points apart; colors that survive on the blue axis (primary 42,
success 52, info 64) sit closer. success stays purple rather than green,
because green next to red error is the worst possible pair under this
vision."
```

---

### Task 2: Move every surface down one rung of the base ramp

Applies the approved surface rule: `base-100` white is any raised surface, `base-200` linen is the page, `base-300` is chrome bands, borders and recessed slots.

**Files:**
- Modify: `web-app/app/views/layouts/books/application.html.erb:19,21,54`
- Modify: `web-app/app/views/books/ranked_items/index.html.erb:8`
- Modify: `web-app/app/components/books/card_component.html.erb:5`
- Modify: `web-app/app/views/books/books/show.html.erb:17`
- Test: none added — see Global Constraints. Verified by build, existing suite, and manual pass.

**Interfaces:**
- Consumes: the `base-100` / `base-200` / `base-300` token values defined in Task 1.
- Produces: nothing consumed by a later task. This is the final task.

- [ ] **Step 1: Put the page on linen**

In `web-app/app/views/layouts/books/application.html.erb`, line 19:

```erb
  <body class="bg-base-200">
```

This is the change that makes the whole thing work. Today `<body>` carries no background class, so the page falls through to `base-100` — pure white, the same as the cards sitting on it.

- [ ] **Step 2: Move the navbar to the deeper warm step**

Same file, line 21:

```erb
    <nav class="navbar bg-base-300" aria-label="Main">
```

Required, not cosmetic: the navbar is `bg-base-200` today, which is the exact token that just became linen. Left alone it would become the same color as the page with no separation at all.

- [ ] **Step 3: Move the footer to the deeper warm step**

Same file, line 54:

```erb
    <footer class="footer footer-center p-10 bg-base-300 text-base-content">
```

Same reasoning as the navbar.

- [ ] **Step 4: Make the hero a white panel**

In `web-app/app/views/books/ranked_items/index.html.erb`, line 8:

```erb
    <div class="bg-base-100 border border-base-300 rounded-xl p-6 md:p-10">
```

Only the background token changes. Keep `border border-base-300 rounded-xl p-6 md:p-10` exactly as-is. It is a panel, and panels are white.

- [ ] **Step 5: Move the card cover slot to the recessed step**

In `web-app/app/components/books/card_component.html.erb`, line 5:

```erb
  <figure class="bg-base-300">
```

This is the empty slot behind a book cover inside a white card, so it takes the recessed step rather than the page color.

- [ ] **Step 6: Move the detail-page cover placeholder to the recessed step**

In `web-app/app/views/books/books/show.html.erb`, line 17:

```erb
          <div class="w-full max-w-[180px] sm:max-w-[240px] lg:max-w-none mx-auto aspect-[2/3] bg-base-300 rounded-lg flex items-center justify-center" aria-hidden="true">
```

Only `bg-base-200` → `bg-base-300`. Every other class on the line stays.

- [ ] **Step 7: Confirm no `bg-base-200` remains in books views**

```bash
cd web-app && grep -rn "bg-base-200" app/views/books/ app/views/layouts/books/ app/components/books/
```

Expected: **no matches**. Every former `bg-base-200` has become either `bg-base-100` (panels) or `bg-base-300` (chrome and recessed slots), and the only remaining `base-200` in books is the page itself on `<body>`.

- [ ] **Step 8: Build the CSS**

```bash
cd web-app && yarn build:css:books
```

Expected: build succeeds.

- [ ] **Step 9: Run the full suite and lint**

```bash
cd web-app && bin/rails test && bundle exec standardrb
```

Expected: 5240 runs, 0 failures, 0 errors, 0 skips; no lint offenses.

Note the one place a false alarm could come from: `test/components/admin/music/songs/wizard/review_step_component_test.rb:152` asserts `tr.bg-base-200`. That is music admin on a different stylesheet and must keep passing untouched. If it fails, something out of scope was edited.

- [ ] **Step 10: Manual verification pass**

Start the dev server with `bin/dev`, then check each of these on the books host:

| Page | What to confirm |
|---|---|
| `/` | Page is warm linen, cards are white and visibly lifted, navbar and footer are a deeper warm band, hero panel reads as a white card |
| `/page/2` | Pagination renders; the current page pill is navy (`btn-primary`), not greyed out |
| `/book/:slug` | Cover card is white on linen; a book with no cover shows the placeholder in the recessed warm tone |
| `/lists` | Search field, Weight / Recently added buttons look right; active button is navy |
| `/lists/:id` | Ranked list renders on linen |
| A books admin index | Sidebar and navbar are white on linen, borders are warm |
| A books admin form with validation errors | Error text and alerts are the vivid red, clearly distinct from the deep oxblood of any `badge-secondary` nearby |
| A books admin success flash | Success is purple, not green — this is deliberate and correct |

- [ ] **Step 11: Run the books Playwright specs**

Requires the dev server running and `e2e/.env` present.

```bash
cd web-app && yarn test:e2e e2e/tests/books/
```

Expected: all 13 books specs pass — `homepage`, `book-detail`, `lists`, and the 10 under `admin/`.

These target by role and text rather than by color, so they should be unaffected. If every admin spec times out on the public homepage, the e2e admin user lost its role in a dev-DB reseed — fix with `bin/rails e2e:admin`, it is not a failure of this change.

- [ ] **Step 12: Commit**

```bash
git add web-app/app/views/layouts/books/application.html.erb \
        web-app/app/views/books/ranked_items/index.html.erb \
        web-app/app/components/books/card_component.html.erb \
        web-app/app/views/books/books/show.html.erb
git commit -m "Move books surfaces onto the warm linen ramp

Puts the page on base-200 linen so the white panels sitting on it are
finally visible as panels rather than relying on shadows alone.

The navbar and footer move to base-300 because they were base-200 today,
which is the token that just became the page color -- left alone they
would have vanished into it. The ranked-items hero becomes a white panel,
and the two empty cover slots take the recessed warm step."
```

---

## Notes for the implementer

**Why there is no test for the surface changes.** This codebase's convention is that controller and integration tests assert behavior — status codes, params, absence of errors — and never HTML, CSS, or copy. The stated rule is: if a designer could change it freely, don't test it. Background colors are exactly that. Adding `assert_select ".bg-base-200"` would violate the convention and lock the design in place. Verification here is the build, the existing suite as a regression net, and human eyes.

**Why `success` is purple.** It looks like a bug and it is not. The maintainer is red-green colorblind; green success beside red error is the single worst pair under that vision, while purple keeps its blue component and stays separable. This was verified visually with the maintainer against rendered badges. Do not "fix" it to green.

**If linen looks too subtle.** At `#FAF7F1` it is about 2.3% off pure white — deliberately quiet. If it under-delivers at full screen, the fix is to raise `--color-base-200` a notch in the theme block. One token, no structural change, no view edits.
