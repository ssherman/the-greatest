# config/initializers/firebase.rb
#
# The Firebase project every domain authenticates against. NOT a secret: this
# same value is compiled into the public JS bundle
# (app/javascript/services/firebase_auth_service.js), and Firebase web API
# keys are public by design.
#
# Hardcoded on purpose, not read from ENV. Firebase mints every ID token with
# `aud`/`iss` set to this exact project, so the value here MUST match what
# Firebase actually issues — an environment override is a footgun, not a
# feature: production's env file previously set FIREBASE_PROJECT_ID to a
# different (wrong) project, and nothing failed only because nothing read it
# yet. A test that needs a different project can assign
# `Rails.application.config.x.firebase_project_id` directly.
#
# Used to verify the `aud` and `iss` claims of every Firebase ID token. Before
# these were checked, a token minted by ANY Firebase project validated here.
Rails.application.config.x.firebase_project_id = "the-greatest-books"

Rails.application.config.x.firebase_issuer =
  "https://securetoken.google.com/#{Rails.application.config.x.firebase_project_id}"
