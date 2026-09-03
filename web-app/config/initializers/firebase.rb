# config/initializers/firebase.rb
#
# The Firebase project every domain authenticates against. NOT a secret: this
# same value is compiled into the public JS bundle, and Firebase web API keys
# are public by design. It lives here rather than as a bare constant so a test
# can point at a different project, and so there is exactly one place that
# knows the issuer string is derived from it.
#
# Used to verify the `aud` and `iss` claims of every Firebase ID token. Before
# these were checked, a token minted by ANY Firebase project validated here.
Rails.application.config.x.firebase_project_id =
  ENV.fetch("FIREBASE_PROJECT_ID", "the-greatest-books")

Rails.application.config.x.firebase_issuer =
  "https://securetoken.google.com/#{Rails.application.config.x.firebase_project_id}"
