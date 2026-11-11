# frozen_string_literal: true

# The site-styled 404 page. Reached two ways:
#
#   * ErrorPages (the exceptions_app) for a URL no route matches, or an error
#     raised outside ApplicationController's rescue_from;
#   * ApplicationController#render_not_found, which renders this controller's
#     template directly for an ActiveRecord::RecordNotFound.
#
# Global, with the layout resolved from Current.domain like PagesController.
class ErrorsController < ApplicationController
  include DomainLayout

  layout :resolve_layout

  # The exceptions_app replays the ORIGINAL request, so a POST to a dead URL
  # arrives here as a POST without a token. It must still be a 404.
  skip_forgery_protection

  before_action :prevent_caching

  def not_found
    @indexable = false
    render status: :not_found, formats: [:html]
  end
end
