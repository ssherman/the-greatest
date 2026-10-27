import { Controller } from "@hotwired/stimulus"
import {
  loadFirebase,
  firebaseLoaded,
  pendingRedirect,
  markPendingRedirect,
  clearPendingRedirect,
  pendingVerification,
  markPendingVerification,
  clearPendingVerification
} from "../services/firebase_loader"
import { signedInUid, clearUidCookie } from "../services/session_cookie"

// Connects to data-controller="authentication"
//
// What this widget SHOWS comes from tg_uid alone, which mirrors the Rails
// session (see services/session_cookie.js). Firebase is a credential exchange:
// it produces the ID token Rails verifies at sign-in, and it is signed out at
// logout. Its auth-state callback never decides signed-in vs signed-out
// presentation -- when it did, the navbar could say Login on a page whose
// server-rendered content said signed in, because Firebase and Rails forget
// users independently.
export default class extends Controller {
  static targets = [
    "signInButton", "signOutButton", "errorMessage", "loading", "modal",
    "emailInput", "passwordInput", "emailStep", "passwordStep", "emailDisplay",
    "submitButton", "authModeToggle", "forgotPasswordForm", "resetEmailInput",
    "infoMessage", "verificationMessage"
  ]
  static values = {
    reloadAfterAuth: Boolean,
    firebaseSrc: String,
    // The enabled entries from config/auth_providers.json, handed over by the
    // widget. A Stimulus value rather than a JS import because there is no
    // @rollup/plugin-json in this project, and adding one to move a list that
    // Rails already reads would be the wrong trade.
    providers: Array
  }

  connect() {
    this.isSignUpMode = false
    this.storedEmail = null
    // A redirect round trip is a sign-in in flight that started on the
    // previous page. On return Firebase reports the new user before
    // /auth/sign_in has answered, while tg_uid is still absent -- exactly the
    // shape handleAuthStateChange would otherwise sign out as a stranger.
    // auth:success or auth:error ends it, as for a sign-in begun on this page.
    this.signInInFlight = pendingRedirect()
    this.setupEventListeners()
    this.observeLoginModal()
    this.renderSignInState()

    // Readers, signed in or not, never download the 32 KB Firebase SDK just
    // to view a page: tg_uid answers what to show. It is fetched eagerly only
    // when a sign-in is mid-flight (getRedirectResult has to run on the page
    // the provider sent the reader back to) or a refused-but-kept Firebase
    // user is waiting on email verification. Otherwise the login modal's
    // observer or signOut() fetches it on demand.
    if (pendingRedirect() || pendingVerification()) {
      this.firebase().catch((error) => console.error("Firebase eager load failed:", error))
    }
  }

  disconnect() {
    // Clean up event listeners
    window.removeEventListener('auth:success', this.handleAuthSuccess)
    window.removeEventListener('auth:error', this.handleAuthError)
    window.removeEventListener('auth:signout', this.handleSignOut)
    window.removeEventListener('user-list-state:cleared', this.handleStateCleared)
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
    // known yet", not "signed out", so it must not clear the pending-redirect
    // or pending-verification markers. The replay is synchronous, so this flag
    // brackets it exactly.
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
    this.handleStateCleared = this.handleStateCleared.bind(this)

    window.addEventListener('auth:success', this.handleAuthSuccess)
    window.addEventListener('auth:error', this.handleAuthError)
    window.addEventListener('auth:signout', this.handleSignOut)
    // Dispatched by user_list_state_controller when /user_list_state answers
    // 401 and it clears tg_uid, and after any sign-out it hears about.
    window.addEventListener('user-list-state:cleared', this.handleStateCleared)
  }

  // Firebase's auth-state callback. It no longer renders anything; it only
  // keeps the markers honest and signs out a Firebase user Rails does not
  // have a session for.
  handleAuthStateChange(user) {
    // FirebaseAuthService has no way to remove a listener, and the service
    // outlives Turbo visits, so a controller whose element Turbo has replaced
    // still hears every notification. Its signInInFlight is stale -- a sign-in
    // started on the CURRENT page is invisible to it -- so letting it act
    // would sign that sign-in out from under the live controller.
    if (!this.element.isConnected) return

    // Read before the clear below: on a redirect return, the very notification
    // that ends the round trip carries the new user, and Rails has not seen
    // its token yet.
    const redirectWasPending = pendingRedirect()

    // Both markers clear only on a REAL notification, never on the synchronous
    // replay of FirebaseAuthService's constructor-initial null.
    //
    // The redirect marker especially. redirectHandler.initialize() kicks off
    // getRedirectResult() WITHOUT awaiting it, and the replay fires immediately
    // after -- so clearing here unconditionally would drop the marker at the
    // START of that round trip rather than the end. Reload inside that window
    // and every signal is gone at once: tg_uid is unset (Rails has not seen the
    // JWT yet), our marker is cleared, and Firebase has already consumed its
    // own firebase:pendingRedirect key. The next page would not load Firebase,
    // getRedirectResult() would never run, and the sign-in would be silently
    // lost.
    //
    // A real notification means Firebase has settled, and it arrives on both
    // branches -- with a user on success, with null when the reader cancels at
    // the consent screen -- so the marker cannot outlive the redirect either way.
    if (!this._replayingInitialAuthState) {
      clearPendingRedirect()

      // Firebase no longer holds the unverified user, so there is no one left
      // for resendVerification() to send to.
      if (!user && pendingVerification()) {
        clearPendingVerification()
        this.renderSignInState()
      }
    }

    if (user && !redirectWasPending) this.reconcileFirebaseUser(user)
  }

  // Firebase remembers someone Rails does not (no tg_uid): a browser restart
  // after the old session-cookie scheme, a session that expired or was ended
  // elsewhere, a refused sign-in. The page already presents signed out, so
  // this only signs the Firebase user out to match, quietly.
  //
  // Each guard below covers a moment when "Firebase user, no tg_uid" is a
  // sign-in that has not finished, not a stranger. Getting one wrong cancels
  // a real sign-in:
  //   - signInInFlight: Firebase reports the user before /auth/sign_in has
  //     answered and set tg_uid, for OAuth redirects and email/password alike.
  //   - pendingRedirect(): the redirect round trip, until Firebase settles.
  //   - pendingVerification(): Rails refused an unverified address and the
  //     Firebase user is kept on purpose so the resend link works.
  reconcileFirebaseUser(user) {
    if (!user) return
    if (signedInUid()) return
    if (this.signInInFlight) return
    if (pendingRedirect()) return
    if (pendingVerification()) return

    this.signOutFirebaseQuietly('no Rails session')
  }

  // Signs Firebase out and nothing else. Deliberately NOT
  // firebaseAuthService.signOut(): that also POSTs /auth/sign_out and
  // dispatches auth:signout. tg_uid can be missing while the server session
  // is valid (a cleared cookie that /user_list_state would backfill), and a
  // Firebase sign-in in another tab is reported here before that tab's
  // /auth/sign_in answers -- so a reconciliation that also ended the Rails
  // session could destroy a session it knows nothing about, and on admin
  // auth:signout navigates away. Memoised so overlapping triggers (a replay
  // and a real notification, say) sign out once.
  signOutFirebaseQuietly(reason) {
    if (this._quietSignOut) return this._quietSignOut

    this._quietSignOut = this.firebase()
      .then((firebase) => firebase.firebaseAuthService.getAuth().signOut())
      .catch((error) => console.error(`Firebase sign out (${reason}) failed:`, error))
      .finally(() => { this._quietSignOut = null })

    return this._quietSignOut
  }

  // The widget's whole signed-in presentation, from tg_uid. Safe to call any
  // time: it reads the cookie fresh, so it is also the response to every event
  // that changes it.
  renderSignInState() {
    const signedIn = signedInUid() !== null

    if (this.hasSignInButtonTarget) {
      this.signInButtonTarget.style.display = signedIn ? 'none' : 'block'
    }

    if (this.hasSignOutButtonTarget) {
      this.signOutButtonTarget.style.display = signedIn ? 'block' : 'none'
    }

    if (signedIn && this.hasErrorMessageTarget) {
      this.errorMessageTarget.style.display = 'none'
    }

    // Lives inside the sign-in controls, so it can only show while signed out.
    // An unverified email/password reader is never signed in: Rails refused
    // them, there is no session and no tg_uid.
    if (this.hasVerificationMessageTarget) {
      this.verificationMessageTarget.style.display = (!signedIn && pendingVerification()) ? 'block' : 'none'
    }

    this.updateNavbarButton(signedIn)
  }

  // Update navbar button based on sign-in state. data-auth-state is written
  // here and nowhere else, so it says "the click is wired": until connect()
  // runs, the layout's inline onclick opens the login modal whatever the
  // label says. E2E waits on the attribute.
  updateNavbarButton(signedIn) {
    const navbarButton = document.getElementById('navbar_login_button')
    if (navbarButton) {
      if (signedIn) {
        navbarButton.textContent = 'Logout'
        navbarButton.onclick = () => this.signOut()
        navbarButton.className = 'btn btn-outline btn-error'
        navbarButton.dataset.authState = 'signed-in'
      } else {
        navbarButton.textContent = 'Login'
        navbarButton.onclick = () => this.openModal()
        navbarButton.className = 'btn btn-primary'
        navbarButton.dataset.authState = 'signed-out'
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

  // Look up one registry entry by id. Returns null for an unknown id rather
  // than throwing, so a stale button in cached Turbo markup degrades to a
  // visible error instead of an unhandled rejection.
  providerConfig(id) {
    return this.providersValue.find((provider) => provider.id === id) || null
  }

  // Handles every OAuth provider. The button supplies its id through a
  // Stimulus action param, so adding a provider touches config and markup
  // only -- never this file.
  async signInWithOauth(event) {
    event.preventDefault()

    const id = event.params.provider
    const config = this.providerConfig(id)

    if (!config) {
      console.error(`Unknown auth provider: ${id}`)
      this.hideError()
      this.hideInfo()
      this.showError('Sign-in is temporarily unavailable. Please try again.')
      return
    }

    // Before the bundle loads: loading it registers the auth-state callback,
    // and a Firebase user it reports from here on is this sign-in, not a
    // stranger to sign out. auth:success / auth:error clear it, as do the two
    // failure paths below that never reach either event.
    this.signInInFlight = true
    this.showLoading(true)
    this.hideError()
    this.hideInfo()

    // Resolved in its own try, same shape as submitEmailForm: a bundle-load
    // failure (e.g. firebase-auth.js 404s) has an error.message like "failed
    // to load firebase bundle from /assets/firebase-auth-a1b2c3.js", which is
    // meaningless -- and alarming -- in the login modal. A genuine Firebase
    // auth error below (the reader cancelling the provider flow, a real
    // provider error) is still shown verbatim, since that message IS useful.
    let firebase
    try {
      firebase = await this.firebase()
    } catch (error) {
      console.error("Firebase load failed:", error)
      this.signInInFlight = false
      this.showError("Sign-in is temporarily unavailable. Please try again.")
      this.showLoading(false)
      return
    }

    try {
      // Set BEFORE the redirect leaves the page: on return, connect() sees this
      // and eager-loads Firebase so getRedirectResult can run.
      markPendingRedirect()
      await firebase.oauthProvider.signIn(config, event)
    } catch (error) {
      console.error(`${config.label} sign in error:`, error)
      clearPendingRedirect()
      this.signInInFlight = false
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

    // Covers sign-in AND sign-up. Firebase reports the new user as soon as it
    // has signed them in, before handleEmailAuthResult has sent the token to
    // Rails, so tg_uid is still absent when the auth-state callback runs.
    this.signInInFlight = true
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
      this.signInInFlight = false
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
      // Both providers await the round trip to /auth/sign_in, so by here
      // auth:success or auth:error has already fired and cleared this. What
      // reaches here uncleared is a Firebase-side failure (a wrong password,
      // say) that never got as far as Rails.
      this.signInInFlight = false
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
        this.showError(
          "Invalid email or password. If you had an account on the old site and haven't " +
          "set a password here yet, choose Create account with this address."
        )
      }
    } catch {
      this.showError(
        "Invalid email or password. If you had an account on the old site and haven't " +
        "set a password here yet, choose Create account with this address."
      )
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

  // Handle sign out. Rails first, because the Rails session is the one that
  // matters: once it is gone this browser is signed out whatever happens to
  // Firebase next. The old order (Firebase, then Rails) made a Firebase
  // failure look like the whole sign-out failing.
  async signOut(event) {
    if (event) {
      event.preventDefault()
    }

    this.showLoading(true)

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
    } catch (error) {
      console.error('Sign out error:', error)
      this.showError('Sign out failed. Please try again.')
      this.showLoading(false)
      return
    }

    // Rails deleted tg_uid in its response; clearing it here as well means a
    // response that lost its Set-Cookie on the way still renders signed out.
    clearUidCookie()
    clearPendingVerification()

    // Best-effort, and never an error to the reader: Rails has already signed
    // them out. On admin this is the only sign-out control, and a reader who
    // never opened the login modal has not downloaded the bundle yet, so this
    // may be the first load. Firebase only (see signOutFirebaseQuietly) --
    // /auth/sign_out has already run.
    try {
      const firebase = await this.firebase()
      await firebase.firebaseAuthService.getAuth().signOut()
    } catch (error) {
      console.error('Firebase sign out error:', error)
    }

    this.showLoading(false)

    window.dispatchEvent(new CustomEvent('auth:signout', {
      detail: { success: true }
    }))

    this.renderSignInState()
  }

  // Handle successful authentication. /auth/sign_in has answered, so tg_uid is
  // set and the widget can render from it.
  handleAuthSuccess(event) {
    this.signInInFlight = false
    clearPendingVerification()
    this.showLoading(false)
    this.renderSignInState()
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
    this.signInInFlight = false
    this.showLoading(false)

    if (event.detail.code === 'email_verification_required') {
      // Rails refused the token, so there is no session and no tg_uid, and the
      // widget is still showing signed out. The Firebase user is left in place
      // on purpose: resendVerification() reads
      // firebaseAuthService.getCurrentUser(), so signing it out would leave the
      // resend link with no one to send to. The marker is what tells every
      // later page not to treat that Firebase user as a stranger.
      //
      // Marked before renderSignInState, which shows the resend link only
      // while the marker is set.
      markPendingVerification()
      this.renderSignInState()
      this.showInfo(event.detail.error)
      return
    }

    if (event.detail.code === 'account_lookup_failed') {
      // A genuine failure with no resend affordance, so it keeps the ordinary
      // red error box. Firebase signed this reader in client-side before Rails
      // refused the token, and nothing needs that Firebase user afterwards,
      // unlike the verification branch above -- so sign it out rather than
      // leave a refused identity in IndexedDB for the next page to reconcile.
      this.renderSignInState()
      this.showError(event.detail.error)
      this.signOutFirebaseQuietly('refused account lookup')
      return
    }

    this.showError(event.detail.error)
  }

  // Handle sign out event. Also dispatched by FirebaseAuthService.signOut()
  // (the redirect handler's credential-conflict path), not only by signOut()
  // above, so it re-renders rather than assuming the caller did.
  handleSignOut() {
    this.showLoading(false)
    this.renderSignInState()
  }

  // /user_list_state answered 401 and tg_uid is gone, or a sign-out cleared
  // the list state. Present signed out, and if Firebase is already on the page
  // and still holds a user, sign that user out to match. Never fetches the
  // bundle just for this: a reader who has not loaded Firebase has nothing to
  // sign out until something else loads it, and handleAuthStateChange
  // reconciles then.
  async handleStateCleared() {
    this.renderSignInState()

    if (!firebaseLoaded()) return

    try {
      const firebase = await this.firebase()
      this.reconcileFirebaseUser(firebase.firebaseAuthService.getCurrentUser())
    } catch (error) {
      console.error('Firebase reconcile after cleared state failed:', error)
    }
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
}
