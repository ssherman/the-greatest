import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    pollInterval: { type: Number, default: 2000 },
    statusUrl: String,
    stepUrl: String
  }

  static targets = ["progressBar", "statusText", "nextButton"]

  connect() {
    this.pollTimer = null
    // Validate required values before starting
    if (!this.hasStatusUrlValue || !this.hasStepUrlValue) {
      console.error('wizard-step controller missing required statusUrl or stepUrl values')
      return
    }
    // Controller is only attached when job is running, so start polling immediately
    this.startPolling()
  }

  disconnect() {
    this.stopPolling()
  }

  startPolling() {
    this.checkJobStatus()
    this.pollTimer = setInterval(() => {
      this.checkJobStatus()
    }, this.pollIntervalValue)
  }

  stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  async checkJobStatus() {
    try {
      const response = await fetch(
        this.statusUrlValue,
        {
          headers: {
            'Accept': 'application/json',
            'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
          }
        }
      )

      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }

      const data = await response.json()

      this.updateProgress(data.progress, data.metadata)

      if (data.status === 'completed') {
        this.stopPolling()
        this.refreshWizardContent()
      }

      if (data.status === 'failed') {
        this.stopPolling()
        this.showError(data.error)
      }
    } catch (error) {
      console.error('Failed to check job status:', error)
    }
  }

  updateProgress(percent, metadata) {
    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = `${percent}%`
      this.progressBarTarget.setAttribute('aria-valuenow', percent)

      const progressText = this.progressBarTarget.querySelector('.progress-text')
      if (progressText) {
        progressText.textContent = `${percent}%`
      }
    }

    if (this.hasStatusTextTarget && metadata) {
      const processed = metadata.processed_items || 0
      const total = metadata.total_items || 0
      this.statusTextTarget.textContent = `Processing ${processed} of ${total} items...`
    }
  }

  enableNextButton() {
    if (this.hasNextButtonTarget) {
      this.nextButtonTarget.disabled = false
      this.nextButtonTarget.classList.remove('btn-disabled')
    }
  }

  showError(error) {
    const errorDiv = document.createElement('div')
    errorDiv.className = 'alert alert-error mt-4'
    errorDiv.innerHTML = `
      <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" />
      </svg>
      <span>${error || 'An error occurred during processing'}</span>
    `
    this.element.appendChild(errorDiv)
  }

  async refreshWizardContent() {
    // Do a full page visit to ensure navigation component is updated
    // The navigation component is outside the turbo frame, so a frame-only
    // refresh would leave the Next button with stale step_name
    window.Turbo.visit(this.stepUrlValue)
  }
}
