# List page panels — design

**Status:** awaiting Shane's approval
**Size:** a small change

## Intent and why

The top of a books list page (`/lists/:id`) looks sloppy. Shane wants the big sections at the top in
their own panels, and the "How good is this list?" section fixed on a full-size screen, with its
detail hidden until clicked and sliding open.

Why it looks wrong today:

- The weight card is `bg-base-200` and the fact pills are `badge-ghost` (also base-200). The books page
  body is base-200. Measured: all three compute to the same colour, so panel and pills are invisible
  and only their padding shows, as odd indents.
- The breakdown has no width limit, so labels and numbers sit about 1,400px apart at 2000px wide.

## Goals

- Every top section on the books list page is a visible panel.
- The score is visible without a click. The arithmetic is hidden until clicked.
- Breakdown labels and numbers stay close together at every width.
- Nothing scrolls sideways at 320px.

## Non-goals

- Music list pages (they use a different component).
- Redesigning the games list page. It only gets the shared score panel, plus a wrapper (below).
- Changing how weights are calculated, or the wording of any penalty.
- Truncating long descriptions.
- Refreshing the pinned daisyUI reference (it says 5.7.x, 5.8.2 is installed).

## Anti-goals

- A visitor having to click to learn the score.
- Colour as the only thing separating a panel from the page. Every panel has a border.
- New JavaScript.

## Approaches

Layout, shown as working mockups with real list text:

| | Trade-off |
|---|---|
| **A. Score on the side — picked by Shane** | Two columns, 2/3 and 1/3. Opening the arithmetic moves the books down only about 140px on the sample list, and it holds up with no voter info. A short list leaves a gap under the score panel. |
| B. Full-width header, then two panels | Clearest order, but the tallest, and the score panel stretches across the page when there is no voter info. |
| C. Three across | Shortest when closed, but a long description makes one tall narrow column. |

How much shows while closed: the score and the number of things lowering it (**picked by Shane**), over
hiding everything behind one bar.

How it opens (builder's call): native `<details>` with daisyUI `collapse collapse-arrow`. It needs no
JavaScript and is keyboard operable. A hidden checkbox is less accessible, and a Stimulus controller
would rebuild what the browser provides. Measured in Chromium: opens over 0.2s, and instantly under
reduced motion. Firefox and Safari do not support the height animation and may snap open. Accepted.

## Design

### Books list page

```
┌──────────────────────────────────┐ ┌────────────────────┐
│ The Booklist Century             │ │ How good is this   │
│ (Source)(2005)(100 books)(4 v.)  │ │ list?              │
│ Description…                     │ │ Weight 0%          │
│ [View the original list]         │ │ 7 things lower it  │
└──────────────────────────────────┘ │ ┌────────────────┐ │
┌──────────────────────────────────┐ │ │ See how this   │ │
│ Who voted                        │ │ │ was worked out⌄│ │
│ Voter details…                   │ │ └────────────────┘ │
└──────────────────────────────────┘ └────────────────────┘
[books grid, unchanged]
```

- From `lg` up: three-column grid, header and "Who voted" spanning two, score in the third, columns
  aligned to the top. Below `lg`: one column in the order header, who voted, score.
- Panel style: `card bg-base-100 border border-base-300 shadow-sm`, as on the reader profile pages.
- Prose is capped at `68ch` and set to 16px (`card-body` defaults to 14px).
- Fact pills get a base-200 fill and a base-300 border. A long source wraps inside its pill (the longest
  is 88 characters).
- "Who voted" keeps its `data-testid` and today's rule: over 600 characters it sits behind its own
  click-to-open bar. With no voter details the panel is absent.

Two small fixes on lines this touches:

- "1 voters" becomes "1 voter" (200 active lists have exactly one voter).
- Line breaks in descriptions are kept (390 active lists have them and they collapse today).

### Score panel (`Lists::WeightBreakdownComponent`, shared with games)

- Always visible: the "How good is this list?" heading, "Weight N%", and "N things lower it" /
  "1 thing lowers it" / "Nothing lowers it".
- Click-to-open bar: "See how this was worked out". Inside is one `dl` with a divider between rows:
  base weight, each penalty largest first, total penalty, then the bonus, cap and floor rows under
  today's conditions, then final weight. Numbers are tabular, and rows are capped at `max-w-2xl`.
- With no penalties there is no bar. In the dev data no such list has a final weight that differs from
  its base weight.
- The heading stays outside `<summary>`, because some screen readers drop a heading inside one.
- Both fallback messages (no ranked list, no details) stay as they are, with no bar.

### Games list page

The component's panel gains a border because the page itself is base-100. It sits in a `max-w-2xl`
wrapper with bottom margin, since that page has no columns. Nothing else changes.

## Testing

- Component tests: the three count wordings, the bar is present and closed by default, no bar with zero
  penalties or in either fallback, every arithmetic row still rendered. Existing `assert_text` checks on
  rows need `:all`, because Capybara treats content in a closed `<details>` as hidden.
- Controller tests unchanged: status and behaviour only.
- E2E, books and games: the score is visible on load, "Base weight" is not, and clicking the bar
  reveals it. The games spec already checks "Base weight" and needs the click.
- Looked at in a browser at 320, 390, 1024 and 2000px, books and games: panels visible, no sideways
  scroll.

## Left to the builder

Exact spacing, whether the books header becomes a partial, and class details within the rules above.
