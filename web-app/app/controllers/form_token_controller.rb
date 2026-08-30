# Edge-cached public form pages ship a <meta name="csrf-token"> that belongs to
# whoever populated the cache, or to nobody. This hands the caller a token for
# their own session.
#
# Deliberately does no database work: the pages it serves are public, anonymous
# surfaces that have been used to flood the origin before, and this is the one
# uncached endpoint they still touch. Keeping it query-free makes a flood of it
# about as cheap as Rails gets. Each form's Stimulus controller fetches it on
# first interaction with the form, not on page load, so a crawler or a flood
# that never touches the form never reaches it at all.
class FormTokenController < ApplicationController
  include Cacheable

  before_action :prevent_caching

  def show
    render json: {csrf_token: form_authenticity_token}
  end
end
