import firebaseAuthService from '../firebase_auth_service.js'

class RedirectHandler {
  constructor() {
    this.initialized = false
  }

  // Initialize redirect handling
  initialize() {
    if (this.initialized) return this

    // Handle redirect result when page loads
    this.handleRedirectResult()
    
    this.initialized = true
    return this
  }

  // Handle redirect result from OAuth providers
  async handleRedirectResult() {
    try {
      const result = await firebaseAuthService.handleRedirectResult()
      
      if (result) {
        console.log('Redirect authentication successful')
        
        // Check if we should reload the page after successful auth
        const shouldReload = document.body.dataset.reloadAfterAuth === 'true'
        
        if (shouldReload) {
          window.location.reload()
        }
      }
    } catch (error) {
      console.error('Redirect result handling error:', error)
      
      // Handle specific error cases
      if (error.code === 'auth/account-exists-with-different-credential') {
        console.log('Account exists with different credential')
        // Sign out and show appropriate message
        await firebaseAuthService.signOut()
        
        window.dispatchEvent(new CustomEvent('auth:error', {
          detail: { 
            error: 'An account already exists with the same email address but different sign-in credentials.',
            code: error.code
          }
        }))
      } else {
        window.dispatchEvent(new CustomEvent('auth:error', {
          detail: { 
            error: error.message,
            code: error.code
          }
        }))
      }
    }
  }

  // Check if current page load is from a redirect
  isRedirectResult() {
    return window.location.search.includes('apiKey=') || 
           window.location.search.includes('authDomain=')
  }

  // Get redirect result parameters
  getRedirectParams() {
    const urlParams = new URLSearchParams(window.location.search)
    return {
      apiKey: urlParams.get('apiKey'),
      authDomain: urlParams.get('authDomain'),
      continueUrl: urlParams.get('continueUrl')
    }
  }
}

// Create singleton instance
const redirectHandler = new RedirectHandler()

export default redirectHandler 