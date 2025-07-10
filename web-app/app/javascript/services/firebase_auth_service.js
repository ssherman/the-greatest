import { initializeApp } from 'firebase/app'
import { getAuth, onAuthStateChanged, getRedirectResult } from 'firebase/auth'

class FirebaseAuthService {
  constructor() {
    this.app = null
    this.auth = null
    this.currentUser = null
    this.authStateListeners = []
    this.initialized = false
  }

  // Get domain configuration based on hostname
  getDomainConfig() {
    const hostname = window.location.hostname
    const isDev = hostname.includes('dev.') || hostname === 'localhost'
    
    // Extract the base domain from hostname
    let baseDomain = hostname
    
    if (isDev) {
      // Handle dev subdomains like dev.thegreatest.games
      baseDomain = hostname.replace('dev.', '')
    }
    
    // Set authDomain based on current domain
    const authDomain = isDev ? hostname : baseDomain
    
    return {
      isDev,
      baseDomain,
      authDomain
    }
  }

  // Initialize Firebase with domain-aware configuration
  initialize() {
    if (this.initialized) {
      console.log("🔥 Firebase already initialized")
      return this
    }

    console.log("🔥 Initializing Firebase...")
    const domainConfig = this.getDomainConfig()
    
    const firebaseConfig = {
      apiKey: "AIzaSyCrsrT_18mS1K8S5WImMJ7i8DE0a4oAdYI",
      authDomain: domainConfig.authDomain,
      projectId: "the-greatest-books",
      storageBucket: "the-greatest-books.appspot.com",
      messagingSenderId: "735268360576",
      appId: "1:735268360576:web:01ae98f0644a16c25bf165",
      measurementId: "G-NNXC2XRY9X"
    }

    console.log('🔥 Firebase config for domain:', domainConfig.authDomain, firebaseConfig)

    this.app = initializeApp(firebaseConfig)
    this.auth = getAuth(this.app)
    this.initialized = true

    console.log("🔥 Firebase initialized successfully")

    // Set up auth state listener
    this.setupAuthStateListener()
    
    return this
  }

  // Get the Firebase auth instance
  getAuth() {
    if (!this.initialized) {
      console.log("🔥 Firebase not initialized, initializing now...")
      this.initialize()
    }
    return this.auth
  }

  // Set up auth state change listener
  setupAuthStateListener() {
    console.log("👂 Setting up Firebase auth state listener...")
    onAuthStateChanged(this.auth, (user) => {
      console.log("👤 Firebase auth state changed:", user ? user.email : "no user")
      this.currentUser = user
      this.notifyAuthStateListeners(user)
    })
  }

  // Add auth state change listener
  onAuthStateChanged(callback) {
    console.log("📡 Adding auth state listener")
    this.authStateListeners.push(callback)
    
    // If already initialized, call immediately with current state
    if (this.initialized && this.currentUser !== undefined) {
      console.log("📡 Calling listener immediately with current state")
      callback(this.currentUser)
    }
  }

  // Notify all auth state listeners
  notifyAuthStateListeners(user) {
    console.log("📡 Notifying", this.authStateListeners.length, "auth state listeners")
    this.authStateListeners.forEach(callback => {
      try {
        callback(user)
      } catch (error) {
        console.error('Error in auth state listener:', error)
      }
    })
  }

  // Handle redirect result from OAuth flows
  async handleRedirectResult() {
    if (!this.initialized) {
      this.initialize()
    }

    try {
      console.log("🔄 Handling redirect result...")
      const result = await getRedirectResult(this.auth)
      if (result) {
        console.log("✅ Redirect result found, handling auth success")
        await this.handleAuthSuccess(result)
      } else {
        console.log("ℹ️ No redirect result found")
      }
      return result
    } catch (error) {
      console.error('❌ Redirect result error:', error)
      throw error
    }
  }

  // Handle successful authentication
  async handleAuthSuccess(result) {
    console.log("🎉 Handling auth success...")
    const user = result.user
    
    // Get the ID token
    const idToken = await user.getIdToken()
    console.log("🎫 Got ID token")
    
    // Determine provider
    const provider = this.getProviderFromUser(user)
    console.log("🔑 Provider:", provider)
    
    // Send to Rails backend
    await this.sendToBackend(idToken, provider, user)
  }

  // Get provider from Firebase user
  getProviderFromUser(user) {
    if (user.providerData.length > 0) {
      const providerData = user.providerData[0]
      return providerData.providerId.replace('.com', '')
    }
    return 'email'
  }

  // Send authentication data to Rails backend
  async sendToBackend(idToken, provider, user) {
    try {
      console.log("📤 Sending to Rails backend...")
      const domainConfig = this.getDomainConfig()
      
      // Get the full user data including providerData
      const userData = {
        uid: user.uid,
        email: user.email,
        emailVerified: user.emailVerified,
        displayName: user.displayName,
        photoURL: user.photoURL,
        providerData: user.providerData.map(provider => ({
          providerId: provider.providerId,
          uid: provider.uid,
          displayName: provider.displayName,
          email: provider.email,
          phoneNumber: provider.phoneNumber,
          photoURL: provider.photoURL
        })),
        stsTokenManager: user.stsTokenManager,
        createdAt: user.metadata?.creationTime,
        lastLoginAt: user.metadata?.lastSignInTime
      }
      
      const response = await fetch('/auth/sign_in', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        body: JSON.stringify({
          jwt: idToken,
          provider: provider,
          domain: domainConfig.baseDomain,
          user_data: userData
        })
      })

      const data = await response.json()
      console.log("📥 Backend response:", data)
      
      if (!data.success) {
        throw new Error(data.error || 'Authentication failed')
      }

      // Trigger custom event for successful authentication
      console.log("📡 Dispatching auth:success event")
      window.dispatchEvent(new CustomEvent('auth:success', {
        detail: { user: data.user }
      }))

      return data
    } catch (error) {
      console.error('❌ Backend authentication error:', error)
      
      // Trigger custom event for authentication failure
      console.log("📡 Dispatching auth:error event")
      window.dispatchEvent(new CustomEvent('auth:error', {
        detail: { error: error.message }
      }))
      
      throw error
    }
  }

  // Sign out user
  async signOut() {
    if (!this.initialized) {
      this.initialize()
    }

    try {
      console.log("👋 Signing out from Firebase...")
      // Sign out from Firebase
      await this.auth.signOut()
      
      console.log("📤 Signing out from Rails backend...")
      // Sign out from Rails backend
      await fetch('/auth/sign_out', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        }
      })

      // Trigger custom event for sign out
      console.log("📡 Dispatching auth:signout event")
      window.dispatchEvent(new CustomEvent('auth:signout'))
      
    } catch (error) {
      console.error('❌ Sign out error:', error)
      throw error
    }
  }

  // Get current user
  getCurrentUser() {
    return this.currentUser
  }

  // Check if user is authenticated
  isAuthenticated() {
    return this.currentUser !== null
  }
}

// Create singleton instance
const firebaseAuthService = new FirebaseAuthService()

export default firebaseAuthService 