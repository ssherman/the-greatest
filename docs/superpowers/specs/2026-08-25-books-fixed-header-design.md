# Books: always-visible header with a mobile slide-out nav

**Date:** 2026-08-25
**Status:** Design approved, ready for implementation planning
**Scope:** Books domain only

## Goal

Make the books top navigation always visible while scrolling, and replace the mobile
hamburger dropdown with a slide-out drawer.

## Why a drawer, not just a pinned bar

Pinning the current header would break the mobile menu. Measured on the running app,
signed in with the "Lists" submenu open, the dropdown is 541px tall. In phone landscape
(844x390) it already overflows the viewport by 215px, and it has no height limit and no
internal scrolling (`max-height: none`, `overflow-y: visible`).

Today that is survivable: the menu is positioned in the document, so scrolling the page
moves it up and the rest becomes reachable. Verified — scrolling 400px moved the menu
from `top: 64` to `top: -336`.

A pinned header removes exactly that escape hatch. The menu would stay fixed on screen
and its lower portion would become permanently unreachable. So the overflow has to be
solved as part of this change, not after it.

The drawer solves it: daisyUI gives the open panel `overflow-y: auto` and
`overscroll-behavior: contain`. Verified at 844x390 — 675px of panel content in a 390px
viewport, scrolls internally, last link reachable.

## Baseline measurements

Taken against the running dev app before any change.

| Property | Value |
| --- | --- |
| Header height | 64px at every width 360-1920, signed in or out |
| Header wrapping | Never wraps at any measured width |
| Desktop "Lists" dropdown | 362px, fits even in a 1366x640 window |
| Mobile menu, signed out | 438px with Lists expanded |
| Mobile menu, signed in | 541px with Lists expanded (4 extra items) |

The nav never wrapping is worth recording: a previously noted concern about the bar
sliding under the logo at some widths does not reproduce on books today, so this change
does not inherit a wrapping problem.

## Decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Scope | Books only | Music and games duplicate their link markup inline instead of using a partial. Bringing them along is separate work. |
| Header height on mobile | Unchanged, 64px, always | Simplest. Nothing resizes or moves during scroll. |
| Positioning | `sticky`, not `fixed` | Sticky reserves its own space, so no compensating `padding-top` on the body. The legacy site uses `fixed-top` and pays that tax. |
| Panel contents | Links only | Search and Login stay in the pinned bar, reachable without opening the panel. |
| Panel side | Left | Matches where the hamburger already sits. |
| Breakpoint | `lg`, unchanged | Same width at which the hamburger appears today. |
| Submenu style | Inline expanding `<details>` | The legacy site floats a Bootstrap dropdown on top of its offcanvas panel; that is the part that looks bad. |

## Architecture

The books layout body becomes a daisyUI drawer:

```
.drawer
├── input#books-nav-drawer.drawer-toggle    (checkbox holds open/closed state)
├── .drawer-content
│   ├── nav.navbar.sticky.top-0.z-30
│   ├── main#main.scroll-mt-20
│   └── footer, modals, toast region
└── .drawer-side.z-40.lg:hidden
    ├── label.drawer-overlay                (tap outside to close)
    └── vertical nav links
```

`_nav_links.html.erb` continues to be rendered twice — once in the desktop horizontal
bar, once in the drawer panel — so adding a nav link stays a single-file edit.

The hamburger changes from a dropdown trigger to a `<label for="books-nav-drawer">`.

### Why sticky survives inside `drawer-content`

`position: sticky` breaks if any ancestor establishes a scroll container or a containing
block. Verified from the installed daisyUI 5.7.21 source and confirmed in a browser:

```css
.drawer         { display:grid; grid-auto-columns:max-content auto; width:100%; position:relative }
.drawer-content { grid-row-start:1; grid-column-start:2; min-width:0 }
```

Neither element sets `overflow`, `transform`, `filter`, `will-change`, `contain`, or a
height. Measured computed styles on both: `overflow=visible transform=none filter=none
willChange=auto contain=none`. A sticky header inside stayed at `top: 0` after 1500px of
scrolling.

The `will-change: transform` and `translate: -100%` that do exist live on `.drawer-side`'s
children — a sibling subtree, irrelevant to the header. daisyUI also clears them when the
drawer opens.

This is worth stating explicitly because the opposite is widely repeated online. It was
true in daisyUI 2, where `.drawer-content` was `overflow-y: auto` with an inherited
height. It has been false since v4.

**Constraint this creates:** no `overflow-hidden`, `overflow-auto`, or `h-screen` may be
introduced on `<body>`, `.drawer`, `.drawer-content`, or anything between them and the
header. If horizontal clipping is ever needed there, use `overflow-x: clip`, which does
not create a scroll container.

### Z-index

`.drawer-side` defaults to `z-index: 10`; `.drawer` and `.drawer-content` create no
stacking context, so the header competes in the root stacking context. Setting the header
to `z-30` and `.drawer-side` to `z-40` makes the drawer and its dimmed overlay cover the
header. Verified: `elementFromPoint` over the header centre returns `drawer-overlay` while
the drawer is open.

Because the overlay covers the header, the close affordance must live inside the panel —
tapping the header's hamburger is not available while open.

The login modal is a `<dialog>` in the top layer and is unaffected.

## Behavior requiring JavaScript

daisyUI's drawer is pure CSS and works with JavaScript disabled. Four gaps need a small
Stimulus controller.

### 1. Back button restores the drawer open and scroll-locked

The most important one. Turbo's page snapshot is `cloneNode(true)`, and the HTML standard
specifies that cloning an `<input>` propagates its *checkedness*. So the outgoing page is
cached with the checkbox checked.

Sequence: open the drawer, click a link in it, press Back. The drawer is restored open,
and because `:root:has(.drawer-toggle:checked)` re-applies, the page behind is
scroll-locked.

Fix: uncheck the toggle on `turbo:before-cache`.

Note: forward navigation is fine. A normal Turbo Drive visit replaces `<body>` with
freshly parsed HTML, and a morph refresh syncs the checkbox property from the new
document. Both leave it unchecked. Do **not** put `data-turbo-permanent` on the drawer or
toggle — that is the one thing that would wedge it open.

### 2. Escape does not close the drawer

Measured: still open after Escape. Fix: uncheck on Escape.

### 3. Focus leaks behind the overlay

Measured tab order starting from the first panel link: link, link, `BODY`, the toggle,
then a background link inside `drawer-content`. Focus escapes the panel into content the
user cannot see.

Fix: set `inert` on `.drawer-content` while the drawer is open.

Keyboard *opening* already works unaided — Tab reaches the toggle in one press and Space
opens it. daisyUI 5 also draws a focus ring on the label via
`.drawer-toggle:focus-visible ~ .drawer-content label.drawer-button`.

### 4. Crossing the `lg` breakpoint while open strands the panel

`display: none` does not clear `:checked`, and `.drawer-toggle:checked ~ .drawer-side`
still matches. Opening the drawer on a phone and rotating to a width past `lg` leaves the
fixed full-height panel overlaid on the desktop layout.

Fix: `lg:hidden` on `.drawer-side`, plus a `matchMedia` listener that unchecks on cross.

### 5. Clicking a link inside the drawer

daisyUI ships no JavaScript, so the checkbox stays checked. Verified on a static page.
Forward navigation resets it anyway, but unchecking on click gives immediate feedback and
covers links that do not swap the body — in-page anchors and any link targeting a Turbo
frame.

### Also

Mirror `aria-expanded` onto the hamburger. The `<label>` is announced as a label, not as a
control, and daisyUI supplies no `aria-expanded`, `aria-controls`, or button role.

### Not needed

daisyUI 5 already provides the body scroll lock, via `--page-scroll-lock` and root-level
`overflow`. Verified: `<html>` goes from `overflow: visible` to `hidden` when the drawer
opens. This is a v5 addition — v4 had nothing — and it locks the viewport rather than
setting `position: fixed` on `<body>`, which is what causes the well-known iOS
scroll-position jump. It also uses a scroll-driven feature probe to apply
`scrollbar-gutter: stable` only when a scrollbar is actually present, so opening the
drawer causes no layout shift.

## Collateral edits

- `app/views/books/books/show.html.erb` — the sidebar card is `sticky top-8` (32px) and
  would sit 32px under a 64px header. Change to `top-20`. Measured: leaves a 15px gap.
- `#main` in the books layout needs `scroll-mt-20` so the "Skip to content" link does not
  land under the header.

Neither music, games, nor admin is touched. `books/books/show.html.erb` is the only books
view using `sticky`.

## Testing

### Existing test that will fail

`test/controllers/news_posts_controller_test.rb:549`:

```ruby
assert_select ".navbar a[href=?]", "/news", count: 2
```

It loops over books, music, and games. The drawer panel lives outside `.navbar`, so the
books iteration drops to 1 and fails. It needs rescoping to cover both the bar and the
panel while still excluding the footer's own links.

Baseline before any change, in this worktree: `news_posts_controller_test.rb` 80 runs 0
failures; `daisyui_v4_classes_test.rb` 2 runs 0 failures; `test/controllers/books/` 291
runs 0 failures.

### New coverage

Controller test: nav links render in both the desktop bar and the drawer panel, so a
one-copy edit is caught.

Playwright E2E in `web-app/e2e/tests/books/`:

- Header remains at `top: 0` after scrolling.
- Hamburger opens the panel; links are visible.
- Clicking a link navigates **and** the drawer is closed afterwards.
- **Pressing Back leaves the drawer closed** — the regression test for the Turbo
  snapshot bug. Also assert the page still scrolls, since that bug locks scrolling.
- At 844x390 with "Lists" expanded, the last link in the panel is reachable.

The existing `test/lint/daisyui_v4_classes_test.rb` already guards against reintroducing
removed v4 classes.

### Verification notes for the implementer

- daisyUI 5 renamed menu state classes: `active` became `menu-active`. Copying a v4
  sidebar silently loses the active-page highlight.
- The `is-drawer-open:` / `is-drawer-close:` variants exist in 5.7.21 but only match
  inside `.drawer-side` and its descendants. They cannot be used to style the hamburger,
  which lives in `.drawer-content`.
- `.drawer-side` is `height: 100dvh` in v5, with no `100vh` fallback. Do not override it.
- Confirm the desktop "Lists" dropdown still paints above page content once the header is
  a `z-30` stacking context. Verified in a probe, but re-check against the real markup.

## Risks

**iOS scroll lock is unverified on device.** The mechanism is sound and specifically
avoids the known iOS jump bug, but no authoritative confirmation was found that
root-level `overflow: hidden` reliably locks scrolling on current iOS Safari, and
Playwright on Linux cannot prove it. Check on a real iPhone before shipping. If it fails,
only the background-scroll-while-open behavior is affected; the drawer itself still works.

**`:has()` dependency.** The scroll lock relies on `:has()`. Support is broad, and absence
degrades silently — the drawer still opens and closes.

## Out of scope

- Music and games navigation.
- Reducing the number of nav links. The bar is crowded signed in, but it does not wrap at
  any width, so it is not blocking this change.
