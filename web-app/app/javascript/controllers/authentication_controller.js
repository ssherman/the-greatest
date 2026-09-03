import { Controller } from "@hotwired/stimulus"
import {
  loadFirebase,
  likelySignedIn,
  markSignedIn,
  clearSignedInHint,
  markPendingRedirect,
  clearPendingRedirect
} from "../services/firebase_loader"

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
    currentUser: Object,
    firebaseSrc: String
  }

  connect() {
    this.isSignUpMode = false
    this.storedEmail = null
    this.setupEventListeners()
    this.observeLoginModal()

    // Anonymous readers never download the 32 KB Firebase SDK. Anyone with a
    // hint of a session gets it eagerly, so the navbar Login/Logout swap and
    // the post-redirect getRedirectResult still happen on page load.
    if (likelySignedIn()) {
      this.firebase().catch((error) => console.error("Firebase eager load failed:", error))
    } else {
      this.showUnauthenticatedState()
    }
  }

  disconnect() {
    // Clean up event listeners
    window.removeEventListener('auth:success', this.handleAuthSuccess)
    window.removeEventListener('auth:error', this.handleAuthError)
    window.removeEventListener('auth:signout', this.handleSignOut)
    this.modalObserver?.disconnect()
  }

  // Safety net for callers that open #login_modal directly instead of going
  // through openModal() -- user_list_widget_controller, reviews/widget_controller,
  // and membership/show's inline onclick all call showModal() on the dialog
  // itself, and all three are on the anonymous-reader path exactly where
  // deferring the download matters. Watching the dialog's `open` attribute
  // catches every present and future direct-opener in one place, rather than
  // pushing a firebase() call into each call site (including inline ERB
  // onclick, where there is nothing sensible to call). openModal() still
  // calls this.firebase() itself; loadFirebase() is memoised at module scope,
  // so the observer's call here is a free no-op when that happens first.
  observeLoginModal() {
    const modal = document.getElementById('login_modal')
    if (!modal) return // e.g. the admin layout has no login modal

    this.modalObserver = new MutationObserver(() => {
      if (modal.hasAttribute('open')) {
        this.firebase().catch((error) => console.error("Firebase load failed:", error))
      }
    })
    this.modalObserver.observe(modal, { attributes: true, attributeFilter: ['open'] })
  }

  // The ONLY way this controller reaches Firebase. Never import or reference
  // the service singletons directly: in an async refactor of a controller that
  // used to be entirely synchronous, a missed `await` yields undefined and
  // fails silently. One accessor makes a missed await a visible mistake.
  async firebase() {
    if (!this._firebase) {
      this._firebase = await loadFirebase(this.firebaseSrcValue)
      this._initialiseFirebase(this._firebase)
    }
    return this._firebase
  }

  _initialiseFirebase(firebase) {
    if (this._firebaseInitialised) return
    this._firebaseInitialised = true

    firebase.firebaseAuthService.initialize()
    firebase.redirectHandler.initialize()

    // FirebaseAuthService replays its constructor-initial null synchronously to
    // a newly registered listener, before it has read IndexedDB. That is "not
    // known yet", not "signed out", so it must not wipe the localStorage hint --
    // the only signal that survives a browser restart, since tg_uid is a session
    // cookie. The replay is synchronous, so this flag brackets it exactly.
    this._replayingInitialAuthState = true
    firebase.firebaseAuthService.onAuthStateChanged((user) => {
      this.handleAuthStateChange(user)
    })
    this._replayingInitialAuthState = false
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
    // Both markers clear only on a REAL notification, never on the synchronous
    // replay of FirebaseAuthService's constructor-initial null.
    //
    // The redirect marker especially. redirectHandler.initialize() kicks off
    // getRedirectResult() WITHOUT awaiting it, and the replay fires immediately
    // after -- so clearing here unconditionally would drop the marker at the
    // START of that round trip rather than the end. Reload inside that window
    // and every signal is gone at once: tg_uid is unset (Rails has not seen the
    // JWT yet), markSignedIn() has not run, our marker is cleared, and Firebase
    // has already consumed its own firebase:pendingRedirect key. The next page
    // would not load Firebase, getRedirectResult() would never run, and the
    // sign-in would be silently lost.
    //
    // A real notification means Firebase has settled, and it arrives on both
    // branches -- with a user on success, with null when the reader cancels at
    // the consent screen -- so the marker cannot outlive the redirect either way.
    if (!this._replayingInitialAuthState) {
      clearPendingRedirect()
    }

    if (user) {
      markSignedIn()
      this.showAuthenticatedState(user)
    } else {
      if (!this._replayingInitialAuthState) clearSignedInHint()
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
    this.firebase().catch((error) => console.error("Firebase load failed:", error))

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

    // Resolved in its own try, same shape as submitEmailForm: a bundle-load
    // failure (e.g. firebase-auth.js 404s) has an error.message like "failed
    // to load firebase bundle from /assets/firebase-auth-a1b2c3.js", which is
    // meaningless -- and alarming -- in the login modal. A genuine Firebase
    // auth error below (the reader cancelling the Google flow, a real
    // provider error) is still shown verbatim, since that message IS useful.
    let firebase
    try {
      firebase = await this.firebase()
    } catch (error) {
      console.error("Firebase load failed:", error)
      this.showError("Sign-in is temporarily unavailable. Please try again.")
      this.showLoading(false)
      return
    }

    try {
      // Set BEFORE the redirect leaves the page: on return, connect() sees this
      // and eager-loads Firebase so getRedirectResult can run.
      markPendingRedirect()
      await firebase.googleProvider.signIn(event)
    } catch (error) {
      console.error("Google sign in error:", error)
      clearPendingRedirect()
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

    // Resolved before the try, not inside the catch. loadFirebase() nulls its
    // memo on a script-load error, so reaching for getUserFriendlyMessage from
    // inside the catch would re-attempt the load and could reject there --
    // an unhandled rejection with nothing shown to the reader.
    let firebase
    try {
      firebase = await this.firebase()
    } catch (error) {
      console.error("Firebase load failed:", error)
      this.showError('Sign-in is temporarily unavailable. Please try again.')
      this.showLoading(false)
      return
    }

    try {
      if (this.isSignUpMode) {
        await firebase.emailProvider.signUp(email, password)
        this.showInfo('Check your email to verify your account.')
      } else {
        await firebase.emailProvider.signIn(email, password)
      }
    } catch (error) {
      console.error("Email auth error:", error)
      if (!this.isSignUpMode && (error.code === 'auth/invalid-credential' || error.code === 'auth/wrong-password' || error.code === 'auth/user-not-found')) {
        await this.checkProviderConflict(email, error)
      } else {
        this.showError(firebase.emailProvider.getUserFriendlyMessage(error))
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

      // check_provider is rate-limited (Task 7): a throttled request has no
      // has_oauth_provider key at all, which would otherwise silently fall
      // through to the generic invalid-credential message below and hide the
      // real reason from someone who is about to retry into the same limit.
      if (response.status === 429) {
        this.showError(data.error || 'Too many attempts. Please wait a moment and try again.')
      } else if (data.has_oauth_provider) {
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
      const { emailProvider } = await this.firebase()
      await emailProvider.sendPasswordReset(email)
      this.showInfo('If an account exists with this email, a password reset link has been sent.')
    } catch {
      // Show the same message regardless of error (security: don't reveal if
      // the email exists).
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
      const { emailProvider } = await this.firebase()
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

    // Resolved in its own try, same shape as submitEmailForm. On admin this is
    // the only sign-out control on the page, so a failure here (or in the
    // client-side signOut() call below) must never prevent the Rails-side
    // sign-out that follows -- leaving the reader signed in because a client
    // bundle 404'd would be worse than skipping the client Firebase sign-out.
    let firebase = null
    try {
      firebase = await this.firebase()
    } catch (error) {
      console.error('Firebase load failed during sign out:', error)
    }

    if (firebase) {
      try {
        await firebase.firebaseAuthService.signOut()
      } catch (error) {
        console.error('Firebase sign out error:', error)
      }
    }

    clearSignedInHint()

    try {
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
      this.showError('Sign out failed. Please try again.')
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

  // Handle authentication error. email_verification_required is not a failure
  // the reader can fix by retrying -- it means the address already belongs to
  // an account and Firebase has not confirmed they control it, so it gets the
  // resend-verification affordance rather than a red error box.
  handleAuthError(event) {
    this.showLoading(false)

    if (event.detail.code === 'email_verification_required') {
      this.showInfo(event.detail.error)
      if (this.hasVerificationMessageTarget) {
        this.verificationMessageTarget.style.display = 'block'
      }
      return
    }

    this.showError(event.detail.error)
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
