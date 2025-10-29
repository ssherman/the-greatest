import { Controller } from "@hotwired/stimulus"
import firebaseAuthService from "../services/firebase_auth_service"
import googleProvider from "../services/auth_providers/google_provider"
import redirectHandler from "../services/auth_handlers/redirect_handler"

// Connects to data-controller="authentication"
export default class extends Controller {
  static targets = ["signInButton", "signOutButton", "userInfo", "errorMessage", "loading", "modal"]
  static values = { 
    reloadAfterAuth: Boolean,
    currentUser: Object
  }

  connect() {
    console.log("🔌 Authentication controller connected")
    console.log("📋 Controller element:", this.element)
    console.log("🎯 Available targets:", this.hasSignInButtonTarget ? "signInButton" : "NO signInButton")
    
    // Initialize Firebase and redirect handler
    console.log("🔥 Initializing Firebase...")
    firebaseAuthService.initialize()
    redirectHandler.initialize()
    
    // Set up auth state listener
    console.log("👂 Setting up auth state listener...")
    firebaseAuthService.onAuthStateChanged((user) => {
      console.log("👤 Auth state changed:", user ? "User logged in" : "No user")
      this.handleAuthStateChange(user)
    })
    
    // Listen for custom auth events
    console.log("📡 Setting up event listeners...")
    this.setupEventListeners()
    
    console.log("✅ Authentication controller setup complete")
  }

  disconnect() {
    console.log("🔌 Authentication controller disconnected")
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
    console.log("🔄 Handling auth state change:", user ? user.email : "no user")
    if (user) {
      this.showAuthenticatedState(user)
    } else {
      this.showUnauthenticatedState()
    }
  }

  // Show authenticated user state
  showAuthenticatedState(user) {
    console.log("✅ Showing authenticated state for:", user.email)
    this.currentUserValue = {
      id: user.uid,
      email: user.email,
      name: user.displayName,
      photo: user.photoURL
    }
    
    // Update UI elements
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
    
    // Hide any error messages
    if (this.hasErrorMessageTarget) {
      this.errorMessageTarget.style.display = 'none'
    }

    // Update navbar button
    this.updateNavbarButton(user)
  }

  // Show unauthenticated state
  showUnauthenticatedState() {
    console.log("❌ Showing unauthenticated state")
    this.currentUserValue = null
    
    // Update UI elements
    if (this.hasSignInButtonTarget) {
      this.signInButtonTarget.style.display = 'block'
    }
    
    if (this.hasSignOutButtonTarget) {
      this.signOutButtonTarget.style.display = 'none'
    }
    
    if (this.hasUserInfoTarget) {
      this.userInfoTarget.style.display = 'none'
    }

    // Update navbar button
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

  // Handle Google sign in
  async signInWithGoogle(event) {
    console.log("🚀 Google sign in clicked!")
    event.preventDefault()
    
    this.showLoading(true)
    this.hideError()
    
    try {
      console.log("🔐 Calling Google provider sign in...")
      await googleProvider.signIn(event)
      console.log("✅ Google provider sign in completed")
    } catch (error) {
      console.error("❌ Google sign in error:", error)
      this.showError(error.message)
      this.showLoading(false)
    }
  }

  // Handle sign out
  async signOut(event) {
    if (event) {
      event.preventDefault()
    }
    
    this.showLoading(true)
    
    try {
      // Sign out from Firebase
      await firebaseAuthService.signOut()
      
      // Clear Rails session
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

      const data = await response.json()
      console.log("📥 Sign out response:", data)
      
      this.showLoading(false)
      
      // Trigger custom event for successful sign out
      window.dispatchEvent(new CustomEvent('auth:signout', {
        detail: { success: true }
      }))
      
    } catch (error) {
      console.error('❌ Sign out error:', error)
      this.showError(error.message)
      this.showLoading(false)
    }
  }

  // Handle successful authentication
  handleAuthSuccess(event) {
    console.log('🎉 Authentication successful:', event.detail)
    this.showLoading(false)
    
    // Close the modal
    this.closeModal()
    
    // Reload page if needed
    if (this.reloadAfterAuthValue) {
      window.location.reload()
    }
  }

  // Handle authentication error
  handleAuthError(event) {
    console.error('💥 Authentication error:', event.detail)
    this.showError(event.detail.error)
    this.showLoading(false)
  }

  // Handle sign out event
  handleSignOut(event) {
    console.log('👋 User signed out')
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

  // Get current user (for other controllers)
  getCurrentUser() {
    return this.currentUserValue
  }

  // Check if user is authenticated
  isAuthenticated() {
    return this.currentUserValue !== null
  }
}
