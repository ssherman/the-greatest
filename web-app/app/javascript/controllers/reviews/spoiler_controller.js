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

  connect() {
    this.element.querySelectorAll(this.constructor.SELECTOR).forEach((spoiler) => {
      spoiler.setAttribute("tabindex", "0")
      spoiler.setAttribute("role", "button")
      spoiler.setAttribute("aria-expanded", "false")
      spoiler.setAttribute("aria-label", "Show spoiler")
    })
  }

  reveal(event) {
    const spoiler = event.target.closest(this.constructor.SELECTOR)
    if (!spoiler) return

    this.showSpoiler(spoiler)
  }

  revealOnKey(event) {
    if (event.key !== "Enter" && event.key !== " ") return

    const spoiler = event.target.closest(this.constructor.SELECTOR)
    if (!spoiler) return

    event.preventDefault()
    this.showSpoiler(spoiler)
  }

  showSpoiler(spoiler) {
    spoiler.classList.add("review-spoiler--revealed")
    spoiler.setAttribute("aria-expanded", "true")
    spoiler.removeAttribute("aria-label")
    spoiler.removeAttribute("role")
  }
}
