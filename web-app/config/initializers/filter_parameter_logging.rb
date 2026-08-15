# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # Stripe webhook payload fields. ParameterFilter matches at any depth, so
  # these cover the nested card and customer objects in an event body.
  :last4, :exp_month, :exp_year, :postal_code, :address, :customer_details, :billing_details
]
