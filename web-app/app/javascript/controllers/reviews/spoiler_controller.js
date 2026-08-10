import { Controller } from "@hotwired/stimulus"

// Reveals a blurred spoiler inside a review body.
//
// Mounted on the reviews card and delegating downward -- never on the spans. Review
// bodies go through SafeListSanitizer with an allowlist of href/title/class, so a span
// inside a body can never carry its own data-action or Stimulus target. connect() also
// has to add the keyboard affordances for the same reason: the sanitizer strips
// tabindex and role too.
export default class extends Controller {
  static SELECTOR = ".review-spoiler"
  static REVEALED_CLASS = "review-spoiler--revealed"

  connect() {
    this.element.querySelectorAll(this.constructor.SELECTOR).forEach((spoiler) => {
      spoiler.setAttribute("tabindex", "0")
      spoiler.setAttribute("role", "button")
      spoiler.setAttribute("aria-label", "Show spoiler")
    })
  }

  // A click anywhere in an unrevealed spoiler reveals it, including a click that lands
  // on a nested <a> -- ALLOWED_TAGS permits links inside a spoiler body and 119
  // migrated rows have one. preventDefault there so the first click reveals instead of
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
  // ever focusing the spoiler wrapper, and Enter there should follow the link like
  // Enter on any other link does, not get hijacked into a reveal.
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
