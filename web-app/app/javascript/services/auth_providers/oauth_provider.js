import {
  GoogleAuthProvider,
  TwitterAuthProvider,
  FacebookAuthProvider,
  OAuthProvider,
  signInWithRedirect
} from 'firebase/auth'
import firebaseAuthService from '../firebase_auth_service.js'

// The only irreducibly per-provider JavaScript in the app. Everything else
// about a provider -- its id, label, scopes and whether its button renders --
// travels from config/auth_providers.json as data.
//
// Firebase needs a dedicated class for the providers it special-cases; for
// everything else, the generic OAuthProvider constructed with the Firebase id
// is the correct fallback -- Apple included. Every configured provider still
// gets an explicit factory below, even the ones the fallback would build
// correctly on its own, so a provider present in config/auth_providers.json
// but missing here fails at lint time instead of silently at click time. See
// test/lint/auth_provider_registry_test.rb, which pins every configured
// provider to an entry in this map.
const PROVIDER_FACTORIES = {
  'google.com': () => new GoogleAuthProvider(),
  'twitter.com': () => new TwitterAuthProvider(),
  'facebook.com': () => new FacebookAuthProvider(),
  'apple.com': () => new OAuthProvider('apple.com')
}

// Returns a zero-arg factory, never the provider itself -- callers need a
// fresh instance per sign-in attempt, not a shared one. Falling back to a
// generic OAuthProvider built from the id itself means an id absent from the
// map still works (this is what makes the fallback path exercisable at all),
// it just skips the lint test's guarantee.
function providerFactoryFor(firebaseId) {
  return PROVIDER_FACTORIES[firebaseId] || (() => new OAuthProvider(firebaseId))
}

class OauthProvider {
  // config is one entry from the registry: {id, firebase_id, label, scopes}.
  build(config) {
    const provider = providerFactoryFor(config.firebase_id)()

    for (const scope of config.scopes || []) {
      provider.addScope(scope)
    }

    return provider
  }

  async signIn(config, event = null) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    try {
      const auth = firebaseAuthService.getAuth()
      await signInWithRedirect(auth, this.build(config))
    } catch (error) {
      console.error(`${config.label} sign in error:`, error)

      window.dispatchEvent(new CustomEvent('auth:error', {
        detail: {
          error: error.message,
          provider: config.id
        }
      }))

      throw error
    }
  }
}

const oauthProvider = new OauthProvider()

export default oauthProvider
