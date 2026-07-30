import { Controller } from "@hotwired/stimulus"

// Shows/hides target field(s) based on whether a <select>'s current value
// matches a configured value. Used by the descriptions admin forms to hide
// "Source Name" unless Source is "Other".
export default class extends Controller {
  static targets = ["select", "field"]
  static values = { match: String }

  connect() {
    this.toggle()
  }

  toggle() {
    const visible = this.selectTarget.value === this.matchValue
    this.fieldTargets.forEach((field) => field.classList.toggle("hidden", !visible))
  }
}
