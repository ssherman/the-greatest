// Entry point for the build script in your package.json
import "@hotwired/turbo-rails"
import "./controllers"

// Import authentication services for all domains
import "./services/firebase_auth_service"
import "./services/auth_providers/google_provider"
import "./services/auth_providers/email_provider"
import "./services/auth_handlers/redirect_handler"
