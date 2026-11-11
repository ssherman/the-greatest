# frozen_string_literal: true

# The app's exceptions_app (config/application.rb): what a visitor sees when a
# request ends in an error status.
#
# Only a 404 for an HTML request renders through the app, inside the site's own
# layout, because a dead link is the one error a visitor can recover from by
# themselves -- the page keeps the navbar, search and footer they need to do
# it. Every other status is the static page in public/, on purpose: a 500 means
# the app is already failing, and rendering a layout that touches the database
# and the asset build is the surest way to fail a second time.
#
# If the 404 render itself raises, the static 404 is served instead, so a
# broken layout costs a plain page rather than Rails' bare-text fallback.
class ErrorPages
  STATIC = ActionDispatch::PublicExceptions.new(Rails.public_path)

  def self.call(env)
    request = ActionDispatch::Request.new(env)
    return STATIC.call(env) unless request.path_info == "/404" && html?(request)

    begin
      ErrorsController.action(:not_found).call(env)
    rescue => error
      Rails.logger.error { "Dynamic 404 page failed, serving the static one: #{error.class}: #{error.message}" }
      STATIC.call(env)
    end
  end

  # A browser sends text/html; curl and many bots send */*. Both should see the
  # page. A client that asked for something else (an API client sending
  # application/json) gets PublicExceptions' body in its own format.
  def self.html?(request)
    request.formats.any? { |format| format.html? || format == Mime::ALL }
  rescue ActionDispatch::Http::MimeNegotiation::InvalidType
    false
  end
  private_class_method :html?
end
