# Logs a boot-time warning when SENDGRID_API_KEY is absent in production.
#
# config/environments/production.rb deliberately does NOT raise when the key is
# missing (see its Mail section) -- a raise there would crash-loop the web
# container under bin/docker-entrypoint's `bash -e` and 502 all four sites. But
# skipping the raise means ActionMailer's smtp_settings falls back to the mail
# gem's own default (localhost:25), and the resulting send-time failure is a
# bare connection error that names neither SENDGRID_API_KEY nor
# MailDeliverySettings::MissingApiKey anywhere. This line is what an operator
# should grep for instead.
#
# This has to live in an initializer, not in production.rb itself: Rails.logger
# is not installed yet while config/environments/*.rb is still loading
# (config.logger only *records* a logger; the initialize_logger framework
# initializer is what assigns Rails.logger, and that runs after environment
# files finish). Calling Rails.logger.warn from production.rb raises
# NoMethodError: private method 'warn' called for nil.
#
# Log the variable NAME -- never a value.
if Rails.env.production? && ENV["SENDGRID_API_KEY"].blank?
  Rails.logger.warn("SENDGRID_API_KEY is not set; outbound mail will fail at send time")
end

# ActiveJob logs a job's arguments at INFO, and config.filter_parameters does not
# reach them -- so every deliver_later would print the recipient's address, twice.
# This repo is public and its logs must not accumulate donor PII.
ActionMailer::MailDeliveryJob.log_arguments = false
