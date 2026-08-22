# The public news section for every site. One route set, one controller, one set
# of views -- the domain comes from Current.domain and the layout from
# DomainLayout, exactly like MembershipController and MyListsController.
class NewsPostsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include DomainLayout
  include PathBasedPagination

  layout :resolve_layout

  before_action :cache_for_index_page, only: [:index]
  before_action :cache_for_show_page, only: [:show]
  before_action :find_topic, only: [:index]

  PER_PAGE = 10

  def index
    scope = published_scope.includes(:news_topics).recent
    scope = scope.joins(:news_post_topics).where(news_post_topics: {news_topic_id: @topic.id}) if @topic

    @pagy, @news_posts = pagy_path(scope, limit: PER_PAGE)
    @page_title = @topic ? "#{@topic.name} | News" : "News"
    @indexable = @news_posts.any?

    # Self-referential: a URL carrying a tracking parameter (?utm_source=x) or
    # a non-canonical form (/news.html, /news/page/01) is not a distinct share
    # target, and the layout's og:url already prefers this over
    # request.original_url -- see D4 on #show.
    @canonical_url = if @topic
      (@pagy.page > 1) ? news_topic_page_url(topic_slug: @topic.slug, page: @pagy.page) : news_topic_url(topic_slug: @topic.slug)
    elsif @pagy.page > 1
      news_page_url(page: @pagy.page)
    else
      news_url
    end
  end

  def show
    @news_post = published_scope
      .includes(:news_topics, :user)
      .friendly.find(params[:slug])

    @body_html = Services::News::BodyRenderer.call(@news_post.body)
    @canonical_url = news_post_url(slug: @news_post.slug)
    @indexable = true
  end

  private

  # Drafts and future-dated posts are excluded here, not in a view conditional:
  # this scope backs both #index (edge-cached 6 hours) and #show (24 hours),
  # so a draft rendered even once would be served to everyone until the
  # longer of the two entries expired.
  def published_scope
    NewsPost.where(domain: Current.domain).published
  end

  def find_topic
    return if params[:topic_slug].blank?

    @topic = NewsTopic.where(domain: Current.domain).friendly.find(params[:topic_slug])
  end
end
