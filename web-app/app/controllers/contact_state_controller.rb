# The footer is rendered on every public page, and every public page is
# edge-cached, so the form's HTML must be identical for everyone and the
# <meta name="csrf-token"> in the page belongs to whoever populated the cache.
# This hands the caller their own token and their own email address.
#
# Deliberately does no database work beyond loading the session: it is the one
# uncached endpoint a public, anonymous surface touches, and the Stimulus
# controller only calls it when the modal actually opens, so a crawler that
# never opens the modal never reaches it.
class ContactStateController < ApplicationController
  include Cacheable

  before_action :prevent_caching

  def show
    render json: {
      email: current_user&.email,
      csrf_token: form_authenticity_token
    }
  end
end
