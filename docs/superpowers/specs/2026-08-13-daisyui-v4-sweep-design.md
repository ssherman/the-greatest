# daisyUI v4 class sweep — design

**Date:** 2026-08-13
**Status:** approved, ready for planning
**Branch:** `daisyui-v4-sweep`

## Problem

The app runs daisyUI 5 (5.7.16 as of `4eabaa1f`), but templates still carry class names that were
removed in v5. They generate no CSS, so using one is a **silent** failure: no build error, no
runtime error, no visual difference — just dead markup.

The cost is not the dead markup itself. It is that ~112 files contain it, so every instruction to
"follow the existing pattern in a neighbouring file" reproduces the bug. This has surfaced
repeatedly: `.claude/agents/ui-engineer.md` was itself teaching the v4 idiom until 2026-08-11, and
the saved-search form work hit it twice.

## Why now

daisyUI moved 5.7.9 → 5.7.16 in `4eabaa1f` (Tailwind unchanged at 4.3.3). Verified before writing
this spec: the `:where(.fieldset)` label override from PR #221 still resolves correctly under
5.7.16 — field labels 16px/600, option text 14px/400, and a `text-lg` utility on a fieldset still
wins at 18px. **The bump requires no repair.** It is the occasion for this work, not a cause of it.

## Scope: ten dead classes, not five

`test/lint/daisyui_v4_classes_test.rb` guards five. There are ten.

They were found by a method that does not depend on knowing daisyUI's changelog: **Tailwind only
emits CSS for classes it finds in the source, so any class appearing in a template but absent from
the compiled output is provably dead.** Cross-checked against
`docs/external-libraries/daisyui-llms.txt`; all ten are absent from it, and `tabs-box` (the v5
rename of `tabs-boxed`) is present.

| class | occurrences | files | in guard today |
|---|---:|---:|---|
| `label-text` | 360 | 83 | yes |
| `form-control` | 270 | 79 | yes |
| `label-text-alt` | 179 | 46 | **no** |
| `input-bordered` | 139 | 55 | yes |
| `select-bordered` | 36 | 27 | yes |
| `textarea-bordered` | 27 | 24 | yes |
| `input-disabled` | 17 | 10 | **no** |
| `table-hover` | 13 | 13 | **no** |
| `file-input-bordered` | 7 | 7 | **no** |
| `tabs-boxed` | 2 | 2 | **no** |

**1,052 occurrences in the 112 `.erb` files, plus 2 `.js` files and 1 test.** The table sums to
1,050 because it counts tokens inside `class` attributes; the remaining 2 are the single
interpolated `input-disabled` in `autocomplete_component.html.erb`, counted separately below. All
`.erb` occurrences are under `app/views/` or `app/components/` — none elsewhere. Compiled artifacts under
`app/assets/builds/` also contain the strings; they regenerate and are not edited.

**86 of the 112 files are admin.** The public sites are nearly clean: 3 books, 2 music, 2 games, 2
layouts, and a handful of shared components. Admin has 28 Playwright specs, which is what makes a
bulk change there verifiable.

## The insight that determines the risk

**All ten classes are inert today.** They contribute no CSS, so the app already renders exactly as
it would with them deleted. That splits the obvious "modernise the markup" instinct into two jobs
with opposite risk profiles:

- **Deleting the dead names** cannot change rendering. Provable, not merely likely.
- **Converting to the real v5 structure** (`fieldset` / `fieldset-legend` / bare `label`) would
  *add* styling that is not present today, changing label size, spacing, and grouping on all 86
  admin screens.

## Decisions

1. **Keep the admin forms looking identical.** Strip the dead names; do not restructure. This
   removes the pattern that propagates the bug, which is the actual complaint, without a
   screen-by-screen redesign review.
2. **Two PRs**, because merging auto-deploys to production and one of the changes touches a live
   public feature that would otherwise be buried in a 115-file diff.

## PR 1 — unblock (3 files)

A mechanical sweep would ship a functional regression. `filter_controller.js:257` uses `.label-text`
as a **selector hook**, not a style:

```js
const names = checked.map((el) => el.closest("label")?.querySelector(".label-text")?.textContent.trim())
```

This builds the "selected filters" summary on the public books filter. Deleting the class would make
it silently render `Any` instead of the chosen genres.

- Add `data-option-label` to the name span in `books/filter_option_rows_component.html.erb`,
  following the `data-option-value` convention already on that label.
- Point `filter_controller.js` at `[data-option-label]`.
- This also fixes a latent ordering bug: the label contains **two** `label-text` spans (name and
  count), and the current code depends on `querySelector` returning the first.
- Delete `assert_selector "input.input-disabled"` from `test/components/autocomplete_component_test.rb:35`.
  The `assert_selector "input[disabled]"` immediately above it is the real assertion; the deleted
  line asserts a class with no styling.

Covered by the existing books filter e2e specs, which exercise the summary text.

## PR 2 — the sweep (114 files)

112 `.erb` + `user_list_modal_controller.js` + the guard test. `filter_controller.js` is finished in
PR 1, which removes its only reference.

- Strip all ten classes from the 112 `.erb` files. **1,050 of 1,052 occurrences are plain literals**
  inside a `class="…"` / `class: "…"` attribute, so this is scripted, not hand-edited.
- One hand-edit: `app/components/autocomplete_component.html.erb:21`, where `input-disabled` is
  conditionally interpolated —
  `class="input input-bordered w-full <%= 'input-disabled' if disabled %>"`. The interpolation goes
  away with the class.
- Strip `label-text` from the template string in
  `app/javascript/controllers/user_list_modal_controller.js:100`. **An `.erb`-only sweep misses
  JS-generated markup.**
- Where a class attribute is left empty, remove the attribute.
- **Same PR** extends `test/lint/daisyui_v4_classes_test.rb`: `REMOVED_CLASSES` 5 → 10, scan widened
  to `app/javascript/**`, `ALLOWLIST` emptied. This cannot be split out — the guard fails on stale
  allowlist entries by design, so cleaning a file and dropping its allowlist line must land
  together.

## Verification

**The compiled CSS must be byte-identical before and after.** Tailwind emits nothing for these
classes, so if the built `books.css` / `music.css` / `games.css` change at all, something live was
deleted. This is a total check over every rule in every domain, and it is what turns "zero visual
change" into a claim rather than a hope. A naive diff of rendered pages could not cover the same
ground for the cost.

Then, in order: the 28 admin Playwright specs, the books/games/music public specs, the full Rails
suite, and `standardrb`.

## Also delivered

An inventory of places where styling was **silently lost** before this work — 13 tables with no
hover highlight, 2 unstyled tab strips, 10 disabled-input sites. Deleting the dead class makes those
losses permanent and invisible, so they are recorded as a follow-up list to act on separately rather
than folded in here.

## Out of scope

- Restructuring admin forms to the v5 `fieldset` idiom.
- daisyUI's remaining small-text defaults (`--card-fs`, `--font-size-min`, `--fontsize` — cards,
  inputs, buttons at 14px) across books, music, and games.
- Restoring the lost styling catalogued above.
- Movies.

## Risks

- **A dead class used as a JS or test hook.** One found (`label-text`), one stale assertion found
  (`input-disabled`). Both handled in PR 1. The search covered `app/`, `test/`, and `e2e/` for all
  ten names, plus a scan for `class*=` / `class^=` / `class$=` substring selectors (none).
- **Scripted edit damaging a non-class match.** The byte-identical CSS check plus the full suite
  catch this; the script targets class attributes specifically, and the two non-literal occurrences
  are already enumerated.
- **Merge conflicts against concurrent UI work**, given the breadth. Mitigated by landing PR 2
  promptly once opened.
