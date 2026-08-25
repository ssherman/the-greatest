import { Application } from "@hotwired/stimulus"

const application = Application.start()

// Exposed so debug mode can be switched on from the browser console when you
// need it locally (set the `debug` property on window.Stimulus).
//
// Do NOT enable it here: this file runs on every page of every site, so
// leaving it on logs every controller connect and action dispatch for every
// visitor. Guarded by test/lint/stimulus_debug_mode_test.rb -- which scans
// this file as raw text, comments included, so do not write the enabling
// assignment out in full even inside a comment.
window.Stimulus = application

export { application }
