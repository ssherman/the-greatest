import { application } from "./controllers/application"

// Import authentication services
import "./services/firebase_auth_service"
import "./services/auth_providers/google_provider"
import "./services/auth_providers/email_provider"
import "./services/auth_handlers/redirect_handler"

export default application 