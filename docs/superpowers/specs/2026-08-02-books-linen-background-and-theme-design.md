# Books: warm linen background + an owned `books` theme

**Date:** 2026-08-02
**Status:** Design approved
**Scope:** Books only — public site and books admin. Music and games are untouched.

## Problem

Every panel on the public books site is white sitting on a white page. `layouts/books/application.html.erb`
sets no background class on `<body>`, so the page falls through to daisyUI's `base-100` — pure white under
the `cmyk` theme — while cards also use `bg-base-100`. Drop shadows carry the entire burden of separating a
panel from the page, and the result reads flat.

Two secondary problems surfaced while investigating:

1. **The palette is borrowed.** `books/application.css` declares `themes: cmyk --default`, so daisyUI
   upstream owns ~22 of the site's 24 design tokens. A daisyUI version bump can shift the books palette
   with no change on our side.
2. **The palette is a printer-ink joke.** `cmyk` means literally cyan / magenta / yellow — that is why the
   Login button is sky blue. It is the least bookish thing on the site.

## Goals

- A warm, very light, paper-like page background. Panels stay white.
- Apply to the public books site **and** the books admin — they share `books.css` and the theme.
- Stop borrowing `cmyk`; define and own a `books` theme.
- Retune `primary` / `secondary` / `accent` to suit paper.
- **The palette must be legible to a red-green colorblind maintainer.** Colors that must be told apart
  separate by lightness, not hue.

## Non-goals

- No layout or structural changes, no new pages or flows, no component API changes.
- No changes to the music or games domains.
- No new Playwright spec — nothing user-facing is added, only restyled.

## Decisions

### 1. Surface ramp — shift every surface down one rung

Three surface meanings, stated once and applied everywhere:

| Token | Value | Means |
|---|---|---|
| `base-100` | `oklch(100% 0 0)` — white | Any raised surface: cards, panels, modals, dropdowns |
| `base-200` | `oklch(97.7% 0.009 85)` ≈ `#FAF7F1` | The page |
| `base-300` | `oklch(93.5% 0.013 83)` ≈ `#EEE9E0` | Chrome bands, borders, empty/recessed slots |

Four chrome treatments were mocked up: white bars, seamless, warm bands, and a dark "ink" footer.
**Warm bands** was chosen — nav and footer sit one step deeper than the page. It preserves the existing
three-step structure exactly; every surface simply moves down one rung of the ramp it already occupied.

This matters because the navbar and footer are `bg-base-200` today, which is the very token that becomes
linen. Left alone they would silently become the same color as the page, with no separation at all.

Linen (`#FAF7F1`) was chosen over deeper creams and parchments. It is deliberately subtle — about 2.3%
off pure white.

### 2. Own the theme rather than override `cmyk`

daisyUI's theme plugin **merges** a custom theme over a built-in one of the same name. From
`node_modules/daisyui/theme/index.js`:

```js
// Merge custom theme with built-in theme if it exists
if (allThemes[name]) {
  themeTokens = { ...builtinTheme, ...customThemeTokens, ... }
}
```

So overriding `cmyk` in place would have worked with two tokens. **Rejected** — it leaves the rest of the
palette owned by daisyUI upstream. Instead we define a theme named `books` carrying the full token set.

Because `books` is not a built-in name no merge occurs, so every token must be listed explicitly. That is
the point: the books palette becomes ours and cannot drift underneath us.

`themes: false` on the main plugin block prevents any built-in theme from being emitted alongside ours
(`pluginOptionsHandler.js:58` guards on truthiness), so there is exactly one theme definition rather than
two competing on source order.

### 3. Palette — a brightness ladder, not a hue wheel

Direction: **Ink & Oxblood** — navy primary, oxblood secondary, antique gold accent.

The maintainer is red-green colorblind. Under deutan/protan vision, red, green, brown and orange collapse
toward a common yellow-brown axis while blue and purple survive. The palette therefore uses two separation
strategies, in priority order:

1. **Colors that collapse into the yellow-brown axis are separated by lightness** — secondary (38),
   error (55), warning (68) and accent (80) form a ladder with 12–17 points between neighbours, so they
   remain distinguishable when hue conveys nothing.
2. **Colors that survive on the blue axis may sit closer in lightness** — primary (42), success (52) and
   info (64) are navy, purple and blue, which retain their hue difference under red-green CVD.

The one pair that spans both groups and sits close in lightness is **success (52) and error (55)**, just 3
points apart. That is deliberate and relies on strategy 2: purple keeps its blue component where green
would slide into the same brown as the red. It was verified visually with the maintainer rather than
assumed.

| Role | Color | L |
|---|---|---|
| secondary | deep oxblood | 38 |
| primary | navy ink | 42 |
| success | purple | 52 |
| error | vivid red | 55 |
| info | mid blue | 64 |
| warning | amber | 68 |
| accent | antique gold | 80 |

Two collisions were found and deliberately corrected:

- **`secondary` vs `error`.** Oxblood (hue 30) and red (hue 28) are nearly the same hue. Oxblood was
  darkened to L38 and desaturated to C0.09 while error was brightened to L55 and pushed to C0.20 — 17
  lightness points apart, one muted and one vivid.
- **`success` vs `error`.** `success` **stays purple**, not green. Green success beside red error is the
  single worst pair under red-green CVD; purple retains its blue component and stays separable. This
  reverses an earlier recommendation in this design process to "fix" cmyk's purple success to green — that
  advice was wrong for this maintainer.

Verified directly with the maintainer against rendered badges, including a hue-stripped version proving the
set is separable on lightness alone.

**What justified the effort.** Actual usage in the codebase:

- Public books site: `btn-primary` ×4, `badge-primary` ×2, `text-primary` ×1. `secondary` and `accent`
  never appear.
- Books admin: `error` 279, `success` 88, `info` 72, `warning` 57, `secondary` 29, `accent` 11 — and
  `badge-success`, `badge-error`, `badge-warning`, `badge-info` and `badge-secondary` coexist on the same
  screens.

So the brand colors barely matter publicly, and the semantic colors matter enormously in the admin. The
ladder is aimed where the problem actually is.

## The token set

To be written into `web-app/app/assets/stylesheets/books/application.css`:

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

The existing `@layer base` block setting Lora and Playfair Display is unchanged.

## Changes

| File | Change |
|---|---|
| `web-app/app/assets/stylesheets/books/application.css` | Replace `themes: cmyk --default` with the `books` theme block above |
| `web-app/app/views/layouts/books/application.html.erb:2` | `data-theme="cmyk"` → `data-theme="books"` |
| `web-app/app/views/layouts/books/application.html.erb:19` | `<body>` → `<body class="bg-base-200">` |
| `web-app/app/views/layouts/books/application.html.erb:21` | navbar `bg-base-200` → `bg-base-300` |
| `web-app/app/views/layouts/books/application.html.erb:54` | footer `bg-base-200` → `bg-base-300` |
| `web-app/app/views/books/ranked_items/index.html.erb:8` | hero panel `bg-base-200` → `bg-base-100` (it is a panel; panels are white). The existing `border border-base-300 rounded-xl p-6 md:p-10` classes are retained unchanged |
| `web-app/app/components/books/card_component.html.erb:5` | cover figure `bg-base-200` → `bg-base-300` (recessed slot) |
| `web-app/app/views/books/books/show.html.erb:17` | cover placeholder `bg-base-200` → `bg-base-300` |
| `web-app/app/lib/admin/domain_nav.rb:69` | `theme: "cmyk"` → `theme: "books"` |
| `web-app/test/lib/admin/domain_nav_test.rb:19` | `assert_equal "cmyk"` → `assert_equal "books"` |

### The admin chrome needs no view changes, but its content surfaces do

`layouts/admin.html.erb:27` is already `bg-base-200`, `admin/shared/_navbar` and `_sidebar` are already
`bg-base-100`, and the rules are already `border-base-300`. The admin *chrome* picks up the new surfaces
purely from the tokens.

**The admin content surfaces do not, and an earlier version of this spec wrongly claimed the admin needed
no changes at all.** daisyUI ships `.stats` and `.table` with **no `background-color` of their own**, so
they render the page colour through. This is not caused by the linen change — it is pre-existing. Compare
the base ramps:

| Theme | base-100 | base-200 (page) | gap |
|---|---|---|---|
| `light` (music/games admin) | 100% | 98% | 2% |
| `cmyk` (books admin, before) | 100% | 95% | 5% |
| `books` (after) | 100% | 97.7% | 2.3% |

Books admin stat cards were grey-on-grey at 95% before this work, exactly as invisible as linen-on-linen
now. Music and games escape it only because `light` puts base-200 within 2% of white, so a transparent
element reads as near-white by accident.

The fix is a rule in `books/application.css` rather than view edits:

```css
@layer components {
  .stats,
  .table {
    background-color: var(--color-base-100);
  }
}
```

Chosen over editing views because two of the affected components — `admin/lists/show_component` and
`admin/categories/show_component` — are **shared** with music and games, so per-view edits would change
those domains too. The rule cannot leak: each domain compiles its own stylesheet, and the public books
site uses neither `.stats` nor `.table`. `@layer components` (not unlayered) so utility classes still
override it. Verified in the built CSS as the only rule setting a background on either selector.

Side effect, accepted: `table-zebra` alternates rows at `base-200`, which was previously identical to the
page and therefore invisible in every domain. Against a white table it now renders as real striping.

## Verification

- `yarn build:css:books` succeeds, and the built CSS contains the `books` theme exactly once with no
  `cmyk` definition remaining. (`app/assets/builds/` is gitignored — nothing to commit.)
- `bin/rails test` — one assertion changes (`domain_nav_test.rb:19`). The only other `bg-base-200`
  assertion in the suite is `test/components/admin/music/songs/wizard/review_step_component_test.rb:152`,
  which is music admin on a different stylesheet and is unaffected.
- `bundle exec standardrb`.
- Manual pass: `/`, `/page/2`, `/book/:slug`, `/lists`, `/lists/:id`, plus a books admin index, a form with
  validation errors, and a success flash.
- No new Playwright spec is owed. Existing books E2E specs target by role and text, not by color.

## Risks

- **Linen may be too subtle.** At `#FAF7F1` it is ~2.3% off white; it read well in a mockup tile beside a
  grey gutter, and full-bleed it may land quieter. Mitigation: bump `--color-base-200` one notch. One
  token, no structural change.
- **The admin changes noticeably.** Navy buttons replace cyan across every books admin screen. This is the
  intended retune, and it is confined to books.
- **`accent` (L80) and `warning` (L68)** sit 12 points apart with adjacent hues — the narrowest pair within
  the yellow-brown group. Accepted: `badge-accent` appears twice in the entire admin.
- **`primary` (L42) and `success` (L52) are the weakest pair in the palette.** Both sit on the blue axis
  only 10 points apart, and deuteranopia strips purple's red component so it shifts *toward* navy rather
  than away. They genuinely coexist: `badge-primary` appears 48 times in the admin against
  `badge-success`'s 30. Accepted on the strength of direct visual confirmation from the maintainer against
  the rendered badge set, plus the fact that daisyUI badges carry text labels, so hue is never the sole
  carrier of meaning. If it proves uncomfortable in real use, the fix is to spread the blue group to
  primary 40 / success 55 / info 70, which widens both gaps to 15 points; note this pushes `success` onto
  the same lightness as `error`, which is tolerable only because purple-vs-red separates on hue.
