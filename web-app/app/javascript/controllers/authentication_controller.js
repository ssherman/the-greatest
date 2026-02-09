import { Controller } from "@hotwired/stimulus"
import firebaseAuthService from "../services/firebase_auth_service"
import googleProvider from "../services/auth_providers/google_provider"
import emailProvider from "../services/auth_providers/email_provider"
import redirectHandler from "../services/auth_handlers/redirect_handler"

// Connects to data-controller="authentication"
export default class extends Controller {
  static targets = [
    "signInButton", "signOutButton", "userInfo", "errorMessage", "loading", "modal",
    "emailInput", "passwordInput", "emailStep", "passwordStep", "emailDisplay",
    "submitButton", "authModeToggle", "forgotPasswordForm", "resetEmailInput",
    "infoMessage", "verificationMessage"
  ]
  static values = {
    reloadAfterAuth: Boolean,
    currentUser: Object
  }

  connect() {
    console.log("Authentication controller connected")
    this.isSignUpMode = false
    this.storedEmail = null

    // Initialize Firebase and redirect handler
    firebaseAuthService.initialize()
    redirectHandler.initialize()

    // Set up auth state listener
    firebaseAuthService.onAuthStateChanged((user) => {
      this.handleAuthStateChange(user)
    })

    // Listen for custom auth events
    this.setupEventListeners()
  }

  disconnect() {
    // Clean up event listeners
    window.removeEventListener('auth:success', this.handleAuthSuccess)
    window.removeEventListener('auth:error', this.handleAuthError)
    window.removeEventListener('auth:signout', this.handleSignOut)
  }

  setupEventListeners() {
    this.handleAuthSuccess = this.handleAuthSuccess.bind(this)
    this.handleAuthError = this.handleAuthError.bind(this)
    this.handleSignOut = this.handleSignOut.bind(this)

    window.addEventListener('auth:success', this.handleAuthSuccess)
    window.addEventListener('auth:error', this.handleAuthError)
    window.addEventListener('auth:signout', this.handleSignOut)
  }

  // Handle authentication state changes
  handleAuthStateChange(user) {
    if (user) {
      this.showAuthenticatedState(user)
    } else {
      this.showUnauthenticatedState()
    }
  }

  // Show authenticated user state
  showAuthenticatedState(user) {
    this.currentUserValue = {
      id: user.uid,
      email: user.email,
      name: user.displayName,
      photo: user.photoURL
    }

    if (this.hasSignInButtonTarget) {
      this.signInButtonTarget.style.display = 'none'
    }

    if (this.hasSignOutButtonTarget) {
      this.signOutButtonTarget.style.display = 'block'
    }

    if (this.hasUserInfoTarget) {
      this.userInfoTarget.style.display = 'block'
      this.userInfoTarget.innerHTML = this.buildUserInfoHTML(user)
    }

    if (this.hasErrorMessageTarget) {
      this.errorMessageTarget.style.display = 'none'
    }

    // Show resend verification for unverified email/password users
    if (this.hasVerificationMessageTarget) {
      const isEmailProvider = user.providerData?.some(p => p.providerId === 'password')
      this.verificationMessageTarget.style.display = (isEmailProvider && !user.emailVerified) ? 'block' : 'none'
    }

    this.updateNavbarButton(user)
  }

  // Show unauthenticated state
  showUnauthenticatedState() {
    this.currentUserValue = null

    if (this.hasSignInButtonTarget) {
      this.signInButtonTarget.style.display = 'block'
    }

    if (this.hasSignOutButtonTarget) {
      this.signOutButtonTarget.style.display = 'none'
    }

    if (this.hasUserInfoTarget) {
      this.userInfoTarget.style.display = 'none'
    }

    if (this.hasVerificationMessageTarget) {
      this.verificationMessageTarget.style.display = 'none'
    }

    this.updateNavbarButton(null)
  }

  // Update navbar button based on auth state
  updateNavbarButton(user) {
    const navbarButton = document.getElementById('navbar_login_button')
    if (navbarButton) {
      if (user) {
        navbarButton.textContent = 'Logout'
        navbarButton.onclick = () => this.signOut()
        navbarButton.className = 'btn btn-outline btn-error'
      } else {
        navbarButton.textContent = 'Login'
        navbarButton.onclick = () => this.openModal()
        navbarButton.className = 'btn btn-primary'
      }
    }
  }

  // Open the login modal
  openModal() {
    const modal = document.getElementById('login_modal')
    if (modal) {
      modal.showModal()
    }
  }

  // Close the login modal
  closeModal() {
    const modal = document.getElementById('login_modal')
    if (modal) {
      modal.close()
    }
  }

  // Build user info HTML
  buildUserInfoHTML(user) {
    const photo = user.photoURL ? `<img src="${user.photoURL}" alt="Profile" class="w-8 h-8 rounded-full mr-2">` : ''
    const name = user.displayName || user.email

    return `
      <div class="flex items-center">
        ${photo}
        <span class="text-sm font-medium">${name}</span>
      </div>
    `
  }

  // Step 1 → Step 2: validate email and transition
  continueWithEmail(event) {
    event.preventDefault()
    this.hideError()
    this.hideInfo()

    const email = this.emailInputTarget.value.trim()
    if (!email) return

    this.storedEmail = email

    // Show email in step 2 display
    if (this.hasEmailDisplayTarget) {
      this.emailDisplayTarget.textContent = email
    }

    // Pre-fill forgot password email
    if (this.hasResetEmailInputTarget) {
      this.resetEmailInputTarget.value = email
    }

    // Reset to sign-in mode
    this.isSignUpMode = false
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.textContent = 'Sign In'
    }
    if (this.hasAuthModeToggleTarget) {
      this.authModeToggleTarget.textContent = 'Create account'
    }

    // Transition: hide step 1, show step 2
    if (this.hasEmailStepTarget) {
      this.emailStepTarget.classList.add('hidden')
    }
    if (this.hasPasswordStepTarget) {
      this.passwordStepTarget.classList.remove('hidden')
      // Focus password input
      if (this.hasPasswordInputTarget) {
        this.passwordInputTarget.value = ''
        this.passwordInputTarget.focus()
      }
    }
  }

  // Step 2 → Step 1: go back to change email
  changeEmail(event) {
    event.preventDefault()
    this.hideError()
    this.hideInfo()

    // Transition: show step 1, hide step 2
    if (this.hasPasswordStepTarget) {
      this.passwordStepTarget.classList.add('hidden')
    }
    if (this.hasEmailStepTarget) {
      this.emailStepTarget.classList.remove('hidden')
      // Focus email input with current value
      if (this.hasEmailInputTarget) {
        this.emailInputTarget.focus()
      }
    }
  }

  // Handle Google sign in
  async signInWithGoogle(event) {
    event.preventDefault()

    this.showLoading(true)
    this.hideError()
    this.hideInfo()

    try {
      await googleProvider.signIn(event)
    } catch (error) {
      console.error("Google sign in error:", error)
      this.showError(error.message)
      this.showLoading(false)
    }
  }

  // Handle email/password form submission (sign in or sign up based on mode)
  async submitEmailForm(event) {
    event.preventDefault()

    const email = this.storedEmail
    const password = this.passwordInputTarget.value

    if (!email || !password) return

    this.showLoading(true)
    this.hideError()
    this.hideInfo()

    try {
      if (this.isSignUpMode) {
        await emailProvider.signUp(email, password)
        this.showInfo('Check your email to verify your account.')
      } else {
        await emailProvider.signIn(email, password)
      }
    } catch (error) {
      console.error("Email auth error:", error)
      if (!this.isSignUpMode && (error.code === 'auth/invalid-credential' || error.code === 'auth/wrong-password' || error.code === 'auth/user-not-found')) {
        await this.checkProviderConflict(email, error)
      } else {
        this.showError(emailProvider.getUserFriendlyMessage(error))
      }
    } finally {
      this.showLoading(false)
    }
  }

  // Check if email is registered with an OAuth provider
  async checkProviderConflict(email, originalError) {
    try {
      const response = await fetch('/auth/check_provider', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        body: JSON.stringify({ email })
      })

      const data = await response.json()

      if (data.has_oauth_provider) {
        this.showError(data.message)
      } else {
        this.showError('Invalid email or password.')
      }
    } catch {
      this.showError('Invalid email or password.')
    }
  }

  // Toggle between sign in and sign up modes in step 2
  toggleAuthMode(event) {
    event.preventDefault()
    this.isSignUpMode = !this.isSignUpMode
    this.hideError()
    this.hideInfo()

    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.textContent = this.isSignUpMode ? 'Create Account' : 'Sign In'
    }

    if (this.hasAuthModeToggleTarget) {
      this.authModeToggleTarget.textContent = this.isSignUpMode
        ? 'Sign in instead'
        : 'Create account'
    }
  }

  // Show forgot password form
  showForgotPassword(event) {
    event.preventDefault()
    this.hideError()
    this.hideInfo()

    if (this.hasPasswordStepTarget) {
      this.passwordStepTarget.classList.add('hidden')
    }
    if (this.hasForgotPasswordFormTarget) {
      this.forgotPasswordFormTarget.style.display = 'block'
    }
  }

  // Back to sign in from forgot password
  backToSignIn(event) {
    event.preventDefault()
    this.hideError()
    this.hideInfo()

    if (this.hasForgotPasswordFormTarget) {
      this.forgotPasswordFormTarget.style.display = 'none'
    }
    // Go back to step 2 (password step) since we already have the email
    if (this.storedEmail && this.hasPasswordStepTarget) {
      this.passwordStepTarget.classList.remove('hidden')
    } else if (this.hasEmailStepTarget) {
      this.emailStepTarget.classList.remove('hidden')
    }
  }

  // Submit forgot password form
  async submitForgotPassword(event) {
    event.preventDefault()

    const email = this.resetEmailInputTarget.value.trim()
    if (!email) return

    this.showLoading(true)
    this.hideError()
    this.hideInfo()

    try {
      await emailProvider.sendPasswordReset(email)
      this.showInfo('If an account exists with this email, a password reset link has been sent.')
    } catch {
      // Show same message regardless of error (security: don't reveal if email exists)
      this.showInfo('If an account exists with this email, a password reset link has been sent.')
    } finally {
      this.showLoading(false)
    }
  }

  // Resend verification email
  async resendVerification(event) {
    event.preventDefault()
    this.hideError()
    this.hideInfo()

    try {
      await emailProvider.resendVerification()
      this.showInfo('Verification email sent. Check your inbox.')
    } catch (error) {
      console.error("Resend verification error:", error)
      this.showError('Failed to send verification email. Please try again later.')
    }
  }

  // Handle sign out
  async signOut(event) {
    if (event) {
      event.preventDefault()
    }

    this.showLoading(true)

    try {
      await firebaseAuthService.signOut()

      const response = await fetch('/auth/sign_out', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')
        }
      })

      if (!response.ok) {
        throw new Error('Failed to clear session')
      }

      this.showLoading(false)

      window.dispatchEvent(new CustomEvent('auth:signout', {
        detail: { success: true }
      }))

    } catch (error) {
      console.error('Sign out error:', error)
      this.showError(error.message)
      this.showLoading(false)
    }
  }

  // Handle successful authentication
  handleAuthSuccess(event) {
    this.showLoading(false)
    this.closeModal()

    if (this.reloadAfterAuthValue) {
      window.location.reload()
    }
  }

  // Handle authentication error
  handleAuthError(event) {
    this.showError(event.detail.error)
    this.showLoading(false)
  }

  // Handle sign out event
  handleSignOut() {
    this.showLoading(false)
  }

  // Show loading state
  showLoading(show) {
    if (this.hasLoadingTarget) {
      this.loadingTarget.style.display = show ? 'block' : 'none'
    }
  }

  // Show error message
  showError(message) {
    if (this.hasErrorMessageTarget) {
      this.errorMessageTarget.textContent = message
      this.errorMessageTarget.style.display = 'block'
    }
  }

  // Hide error message
  hideError() {
    if (this.hasErrorMessageTarget) {
      this.errorMessageTarget.style.display = 'none'
    }
  }

  // Show info message
  showInfo(message) {
    if (this.hasInfoMessageTarget) {
      this.infoMessageTarget.textContent = message
      this.infoMessageTarget.style.display = 'block'
    }
  }

  // Hide info message
  hideInfo() {
    if (this.hasInfoMessageTarget) {
      this.infoMessageTarget.style.display = 'none'
    }
  }

  // Get current user (for other controllers)
  getCurrentUser() {
    return this.currentUserValue
  }

  // Check if user is authenticated
  isAuthenticated() {
    return this.currentUserValue !== null
  }
}
