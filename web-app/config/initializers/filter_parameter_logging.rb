# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # Stripe webhook payload fields. ParameterFilter matches at any depth, so
  # these cover the nested card and customer objects in an event body.
  :last4, :exp_month, :exp_year, :postal_code, :address, :customer_details, :billing_details,
  # :data covers the entire Stripe webhook object (data.object.*), where customer
  # name, phone and free-text description live -- Rails logs parsed params before
  # the action runs, so filtering at the controller is not an option. Leaves the
  # event envelope (id, type, livemode, created) legible for debugging. It also
  # matches this app's auth_data/provider_data/old_user_data blobs, which should
  # be filtered regardless.
  :data,
  # The admin memberships/stripe_events/billing_plans searches all take a free-text
  # `q` and an admin routinely searches by a customer's email address -- filtering
  # the key :email does nothing when the value arrives under :q instead. This app
  # is open source; its production logs should not accumulate donor PII.
  :q
]
