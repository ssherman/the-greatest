import { GoogleAuthProvider, signInWithRedirect } from 'firebase/auth'
import firebaseAuthService from '../firebase_auth_service.js'

class GoogleProvider {
  constructor() {
    this.provider = new GoogleAuthProvider()
    this.setupProvider()
  }

  // Configure Google provider with required scopes
  setupProvider() {
    this.provider.addScope('profile')
    this.provider.addScope('email')
  }

  // Sign in with Google using redirect
  async signIn(event = null) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    try {
      const auth = firebaseAuthService.getAuth()
      await signInWithRedirect(auth, this.provider)
    } catch (error) {
      console.error('Google sign in error:', error)
      
      // Trigger custom event for authentication error
      window.dispatchEvent(new CustomEvent('auth:error', {
        detail: { 
          error: error.message,
          provider: 'google'
        }
      }))
      
      throw error
    }
  }

  // Get provider instance (for advanced configuration)
  getProvider() {
    return this.provider
  }
}

// Create singleton instance
const googleProvider = new GoogleProvider()

export default googleProvider 