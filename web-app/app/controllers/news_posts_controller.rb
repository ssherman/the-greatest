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
  before_action :find_topic, only: [:index]

  PER_PAGE = 10

  def index
    scope = published_scope.includes(:news_topics).recent
    scope = scope.joins(:news_post_topics).where(news_post_topics: {news_topic_id: @topic.id}) if @topic

    @pagy, @news_posts = pagy_path(scope, limit: PER_PAGE)
    @page_title = @topic ? "#{@topic.name} | News" : "News"
    @indexable = @news_posts.any?
  end

  private

  # Drafts and future-dated posts are excluded here, not in a view conditional:
  # these responses are edge-cached for six hours, so a draft rendered even once
  # would be served to everyone until the entry expired.
  def published_scope
    NewsPost.where(domain: Current.domain).published
  end

  def find_topic
    return if params[:topic_slug].blank?

    @topic = NewsTopic.where(domain: Current.domain).friendly.find(params[:topic_slug])
  end
end
