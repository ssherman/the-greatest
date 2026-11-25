# Book submission strip as alerts

Approved by Shane 2026-11-25. Changes the strip of `2026-11-23-user-added-books-design.md` section 6 only:
its look, its copy, and what it shows when the page has stopped checking. Nothing about requests,
lookups or review changes.

## Why

On the list page a pasted Amazon link filled four lines of plain text, the buttons drifted away from
their row on wide screens, and nothing showed that work was going on.

## Approaches

- **One alert per request (picked).** Stands out, carries its own state and buttons, and matches the
  Goodreads import page's progress alert. Tall with many requests; one to three is usual.
- One card with a row per request: calmer, but stands out less.
- A placeholder cover in the grid: hidden by paging, sorting and the table view.

## Design

- Each request is a daisyUI `alert alert-soft`, as wide as the search box, newest first. On a phone the
  buttons sit under the text; from `sm` up they sit beside it. Text and icons keep `base-content`
  (a soft alert's own text color is too pale on this theme), and each alert has a gray outline, because
  the soft warning fill is close to the page color.
- The wrapper stays the one polite live region, so no alert gets a `role`. Icons and the spinner are
  hidden from screen readers.
- The reader never sees the pasted link. A request is called by its title when we have one, else
  "a book from Goodreads", "a book from Amazon" or "a book by ISBN", with a short reference on a second
  line: "Goodreads book 5107", "Amazon item 0593188985", "ISBN 9780061054884". The references come from
  the parsed ids, so they are short and hold no reader text. Admins still see the link.
- Every state has its own words and icon; color only supports them.

| State | Alert | Icon | Text |
|---|---|---|---|
| queued, looking_up | info | spinner | Adding "Title" / Adding a book from Amazon, then "It can take a while. You can leave this page and we'll still add it." |
| needs_details | warning | warning | We couldn't find a book from that link. / a book with that ISBN. / that book. The button says "Try another way". |
| added | success | check | Added "Title" / Already on the site: added "Title" |
| failed | warning | warning | Could not add "Title" |
| rejected | warning | warning | We couldn't verify "Title", so it was removed. |

- **View book** on an added row, to the book's own page, because a new book lands at the end of the list.
- **Honest spinner.** When the page stops checking (10 minutes, or a check that failed) the poller sets
  `data-stalled` on the wrapper. The spinner gives way to a clock and the second line to "Still working
  on it. Reload the page to check." Starting to poll again removes it.

## Left to the builder

Icon drawings and spacing. Tests: the component per state, the controller tests that pin the old copy,
the E2E spec's real and stubbed rows, and the stalled state.
