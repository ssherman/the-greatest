// Loaded on demand by services/firebase_loader.js, never by a layout.
//
// It is a separate rollup entry rather than a dynamic import() because
// Propshaft rewrites only explicit RAILS_ASSET_URL() markers, never ES import
// specifiers: a rollup-generated chunk referenced as ./chunk-abc.js would
// resolve to an undigested /assets/chunk-abc.js and 404 in production. An
// injected <script src> with a Rails-provided asset_path sidesteps that
// entirely.
import firebaseAuthService from "../services/firebase_auth_service"
import oauthProvider from "../services/auth_providers/oauth_provider"
import emailProvider from "../services/auth_providers/email_provider"
import redirectHandler from "../services/auth_handlers/redirect_handler"

// oauthProvider is generic: the Stimulus controller passes it one registry
// entry per click, so a new provider needs no change here. emailProvider stays
// separate on purpose -- no redirect, plus signup, reset and verification.
window.__tgFirebase = { firebaseAuthService, oauthProvider, emailProvider, redirectHandler }
