import { Controller } from "@hotwired/stimulus"

// Reveals a blurred spoiler inside a review body.
//
// Mounted on the reviews card and delegating downward -- never on the spans. Review
// bodies go through SafeListSanitizer with a render-time allowlist of just href (NOT
// title -- see BodySanitizer::RENDER_ATTRIBUTES; a title on a spoiler span leaked its
// text through the browser's native tooltip, so title must never come back), so a span
// inside a body can never carry its own data-action or Stimulus target. connect() also
// has to add the keyboard affordances for the same reason: the sanitizer strips
// tabindex and role too.
export default class extends Controller {
  static SELECTOR = ".review-spoiler"
  static REVEALED_CLASS = "review-spoiler--revealed"

  // Skips a span that already carries REVEALED_CLASS. A Turbo Back restore reconnects
  // this controller against a cached DOM snapshot that still has an earlier reveal's
  // class on it -- without this guard connect() would re-stamp role="button" and
  // aria-label="Show spoiler" onto a span whose text is plainly visible, so a screen
  // reader announces "Show spoiler, button" and never reads the revealed sentence, and
  // both reveal() and revealOnKey() below early-return on that same class, so there
  // would be no way to ever clear it again.
  connect() {
    this.element.querySelectorAll(this.constructor.SELECTOR).forEach((spoiler) => {
      if (spoiler.classList.contains(this.constructor.REVEALED_CLASS)) return

      spoiler.setAttribute("tabindex", "0")
      spoiler.setAttribute("role", "button")
      spoiler.setAttribute("aria-label", "Show spoiler")
    })
  }

  // A click anywhere in an unrevealed spoiler reveals it, including a click that lands
  // on a nested <a> -- ALLOWED_TAGS permits links inside a spoiler body. Measured
  // against the migrated corpus: zero rows have an <a> nested inside a spoiler span
  // (119 rows have a link somewhere in the body, and exactly one row has both a
  // spoiler and a link, elsewhere in the same body). This branch is defensive for the
  // write flow a later increment adds, which can put a link inside a spoiler even
  // though none does yet. preventDefault there so the first click reveals instead of
  // following the link; the guard above already sends a click on an already-revealed
  // spoiler straight through, so a second click on that same link navigates normally.
  reveal(event) {
    const spoiler = event.target.closest(this.constructor.SELECTOR)
    if (!spoiler) return
    if (spoiler.classList.contains(this.constructor.REVEALED_CLASS)) return

    const link = event.target.closest("a")
    if (link && spoiler.contains(link)) event.preventDefault()

    this.showSpoiler(spoiler)
  }

  // Two guards, both unconditional rather than folded into one: an already-revealed
  // spoiler has no role or tabindex left (see showSpoiler) so there is nothing left to
  // act on, and a link nested inside a spoiler is its own independently-focusable,
  // independently-tabbable target -- a keyboard user can land on it directly without
  // ever focusing the spoiler wrapper. Returning early here does NOT hand Enter off to
  // the link and navigate: an un-prevented Enter on a focused <a> fires a native click,
  // which bubbles up to the delegated click->reveal binding on the card. reveal() sees
  // a target inside an unrevealed spoiler and preventDefaults it, so the net effect is
  // the same as a mouse click in that spoiler -- it reveals without navigating, not a
  // followed link. That collapse is arguably the safer behaviour anyway, so it is left
  // alone rather than special-cased.
  revealOnKey(event) {
    if (event.key !== "Enter" && event.key !== " ") return

    const spoiler = event.target.closest(this.constructor.SELECTOR)
    if (!spoiler) return
    if (spoiler.classList.contains(this.constructor.REVEALED_CLASS)) return

    const link = event.target.closest("a")
    if (link && spoiler.contains(link)) return

    event.preventDefault()
    this.showSpoiler(spoiler)
  }

  // A revealed spoiler becomes ordinary text: no tabindex, no role, no label, and no
  // aria-expanded. aria-expanded is only meaningful on a handful of roles, role is
  // removed in this same call, and there is no toggle back to a blurred state -- so
  // setting it (to "true" or anything else) would just be a stray, meaningless
  // attribute rather than an honest description of what's on screen.
  showSpoiler(spoiler) {
    spoiler.classList.add(this.constructor.REVEALED_CLASS)
    spoiler.removeAttribute("tabindex")
    spoiler.removeAttribute("role")
    spoiler.removeAttribute("aria-label")
  }
}
