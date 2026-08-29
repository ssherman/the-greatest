# frozen_string_literal: true

# The public contact address, in one place because AdminMailer's contact-form
# notification and both policy pages all name it. The footer used to render it
# too, as a plain mailto; it now opens the contact form instead (see
# ContactMessagesController), which reads this same address as the mail's
# `to:`, never from anything user-supplied.
#
# Deliberately NOT called Contact: a contact form is the next piece of work here,
# and it will want that constant for a model.
#
# Top-level and not nested, following MailBranding -- a constant looked up from
# inside a nested module resolves against that module first, which has produced
# confusing NameErrors in this codebase more than once.
#
# A plain constant rather than ENV["MAIL_FROM_ADDRESS"]: that variable is the
# envelope-from for outgoing mail, a different job that may later want a
# different address. It also comes from .env, which dotenv loads in the test
# group, so a test asserting on an ENV-derived address passes locally and tells
# you nothing about CI.
module SiteContact
  ADDRESS = "contact@thegreatestbooks.org"
end
