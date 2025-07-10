import { Application } from "@hotwired/stimulus"

const application = Application.start()

// Add debugging
console.log("🎯 Stimulus application started")
console.log("🔍 Looking for controllers...")

// Configure Stimulus development experience
application.debug = true  // Enable debug mode
window.Stimulus   = application

export { application }
