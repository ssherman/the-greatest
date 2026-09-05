import {
  createUserWithEmailAndPassword,
  signInWithEmailAndPassword,
  sendPasswordResetEmail,
  sendEmailVerification
} from 'firebase/auth'
import firebaseAuthService from '../firebase_auth_service.js'

class EmailProvider {
  // Firebase's reset and verification emails link to the project's single
  // default action URL unless told otherwise -- so a games reader resetting a
  // password would be emailed a books link. Deriving from the live origin sends
  // them back to the site they were actually on.
  //
  // Every domain used here must be on Firebase's authorized-domains list, or
  // the SDK rejects the call with auth/unauthorized-continue-uri.
  actionCodeSettings() {
    return {
      url: `${window.location.origin}/`,
      handleCodeInApp: false
    }
  }

  // Sign up with email and password
  async signUp(email, password) {
    try {
      const auth = firebaseAuthService.getAuth()
      const result = await createUserWithEmailAndPassword(auth, email, password)

      // Send verification email
      await sendEmailVerification(result.user, this.actionCodeSettings())

      // Send to backend
      await firebaseAuthService.handleEmailAuthResult(result)

      return result
    } catch (error) {
      console.error('Email sign up error:', error)
      this.dispatchError(error)
      throw error
    }
  }

  // Sign in with email and password
  async signIn(email, password) {
    try {
      const auth = firebaseAuthService.getAuth()
      const result = await signInWithEmailAndPassword(auth, email, password)

      // Send to backend
      await firebaseAuthService.handleEmailAuthResult(result)

      return result
    } catch (error) {
      console.error('Email sign in error:', error)
      throw error
    }
  }

  // Send password reset email
  async sendPasswordReset(email) {
    try {
      const auth = firebaseAuthService.getAuth()
      await sendPasswordResetEmail(auth, email, this.actionCodeSettings())
    } catch (error) {
      console.error('Password reset error:', error)
      throw error
    }
  }

  // Resend verification email to current user
  async resendVerification() {
    try {
      const user = firebaseAuthService.getCurrentUser()
      if (user) {
        await sendEmailVerification(user, this.actionCodeSettings())
      }
    } catch (error) {
      console.error('Resend verification error:', error)
      throw error
    }
  }

  dispatchError(error) {
    window.dispatchEvent(new CustomEvent('auth:error', {
      detail: {
        error: this.getUserFriendlyMessage(error),
        code: error.code,
        provider: 'password'
      }
    }))
  }

  getUserFriendlyMessage(error) {
    switch (error.code) {
      case 'auth/email-already-in-use':
        return 'An account with this email already exists. Try signing in, or use another sign-in method.'
      case 'auth/weak-password':
        return 'Password must be at least 6 characters.'
      case 'auth/invalid-email':
        return 'Please enter a valid email address.'
      case 'auth/user-disabled':
        return 'This account has been disabled.'
      case 'auth/too-many-requests':
        return 'Too many failed attempts. Please try again later.'
      case 'auth/invalid-credential':
        return 'Invalid email or password.'
      default:
        return error.message || 'An error occurred. Please try again.'
    }
  }
}

// Create singleton instance
const emailProvider = new EmailProvider()

export default emailProvider
