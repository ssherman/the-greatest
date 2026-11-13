# Per-host XML sitemaps: an index at /sitemap.xml and child files at
# /sitemaps/<source>-<page>.xml. What each site lists lives in Sitemaps::Registry.
class SitemapsController < ApplicationController
  include Cacheable

  before_action :cache_for_show_page
  before_action :load_base_url

  def index
    @sources = Sitemaps::Registry.sources(current_domain)
    raise ActiveRecord::RecordNotFound if @sources.empty?
  end

  def show
    source = Sitemaps::Registry.find(current_domain, params[:source])
    raise ActiveRecord::RecordNotFound if source.nil?

    page = params[:page].to_i
    size = Sitemaps::Registry.page_size
    raise ActiveRecord::RecordNotFound if page < 1 || page > Sitemaps::Registry.page_count(source)

    @entries = source.entries(offset: (page - 1) * size, limit: size)
  end

  private

  def load_base_url
    @base_url = Api::Host.base_url(current_domain)
  end
end
