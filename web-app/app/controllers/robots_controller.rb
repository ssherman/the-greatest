# Serves /robots.txt for every host. The rules are the old public/robots.txt,
# unchanged; the only per-host addition is a Sitemap line for hosts that have
# sitemap sources. Unconstrained on purpose: every host, movies included, served
# the static file, and a 404 here would be a regression.
class RobotsController < ApplicationController
  include Cacheable

  before_action :cache_for_show_page

  def show
    if Sitemaps::Registry.sources(current_domain).any?
      @sitemap_url = "#{Api::Host.base_url(current_domain)}/sitemap.xml"
    end
    render formats: :text, layout: false
  end
end
