# The correction form page is edge-cached, so the <meta name="csrf-token"> it
# ships belongs to whoever populated the cache, or to nobody. This hands the
# caller a token for their own session.
#
# Deliberately does no database work: the form page it serves is a public,
# anonymous surface that has been used to flood the origin before, and this is
# the one uncached endpoint that surface still touches. Keeping it query-free
# makes a flood of it about as cheap as Rails gets. The Stimulus controller
# fetches it on first interaction with the form, not on page load, so a crawler
# or a flood that never touches the form never reaches it at all.
class CorrectionTokenController < ApplicationController
  include Cacheable

  before_action :prevent_caching

  def show
    render json: {csrf_token: form_authenticity_token}
  end
end
