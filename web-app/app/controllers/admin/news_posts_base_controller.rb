# Domain-agnostic news post CRUD plus the Markdown preview. Each domain
# supplies a routable subclass filling in news_domain and the path helpers, and
# mixing in Admin::DomainScopedAuth itself. Mirrors Admin::ReviewsBaseController.
class Admin::NewsPostsBaseController < Admin::BaseController
  # :only lists here name only the actions this controller implements. This
  # app's test and development environments both set
  # config.action_controller.raise_on_missing_callback_actions = true (Rails
  # 7.1 default), which raises AbstractController::ActionNotFound on EVERY
  # request -- not just a request to the missing action -- the moment a
  # before_action's :only names an action the controller does not define.
  # Verified against this app: listing an action here before the controller
  # defines it 404s every other action too. Any future action must be added to
  # these lists at the same time it is defined below.
  before_action :require_domain_write!, only: [:new, :create, :edit, :update, :destroy, :preview]
  before_action :require_domain_delete!, only: [:destroy]
  before_action :set_news_post, only: [:show, :edit, :update, :destroy]

  helper_method :news_posts_path_for, :news_post_path_for, :new_news_post_path_for,
    :edit_news_post_path_for, :preview_news_posts_path_for

  def index
    # Drafts have a NULL published_at, so they sort first under DESC on
    # Postgres by default. NULLS FIRST is written explicitly anyway so that
    # intent survives in the code rather than resting on a database default:
    # a reader should not have to know Postgres's DESC-NULLS convention to see
    # that drafts are meant to lead the list.
    @news_posts = scope
      .includes(:user, :news_topics)
      .order(Arel.sql("published_at DESC NULLS FIRST, id DESC"))
  end

  def show
  end

  def new
    @news_post = NewsPost.new(domain: news_domain)
  end

  def create
    @news_post = NewsPost.new(news_post_params)
    @news_post.domain = news_domain
    @news_post.user = current_user
    # Does NOT share update's ordering bug: has_many_attached#attach only
    # saves eagerly for a persisted record (`record.persisted? && !record.changed?`);
    # @news_post here is a NEW record, so that branch never runs and the
    # attachment always waits for the @news_post.save below, valid or not.
    attach_body_images

    if @news_post.save
      enqueue_cache_purge(@news_post)
      redirect_to news_post_path_for(@news_post), notice: "Post created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    # Captured BEFORE assign_attributes, and unioned with the post-save set
    # below. An update is the one write where neither state contains the other:
    # unpublishing the 11th post, or dropping the topic that gave a topic index
    # its 11th, REMOVES /news/page/2 (or the topic's page 2), so a set derived
    # only from the saved state sees 10 rows, derives one page, and leaves the
    # disappearing page cached with the retracted post on it for the full 6-hour
    # TTL. Create can only grow the set and destroy only shrink it, so both are
    # covered by a single snapshot on the correct side of the write.
    # Must precede assign_attributes, not merely the save: assigning
    # news_topic_ids on a persisted record writes the join table immediately.
    urls_before = Services::News::CachedUrls.call(@news_post)

    # assign_attributes, THEN check valid? BEFORE attach_body_images, and only
    # attach once known valid: has_many_attached#attach saves eagerly for a
    # persisted, unchanged record (`record.persisted? && !record.changed?`).
    # An earlier version of this method relied on assign_attributes always
    # leaving the record dirty when news_post_params was invalid -- true only
    # because NewsPost currently validates presence on title/body alone, so
    # any failing submission necessarily changes one of them. That is a
    # coupling to today's validation set, not a guarantee: a future
    # content-type or size validation on body_images itself would not dirty
    # any column, and changed? would stay false regardless of ordering. Gating
    # attach_body_images on valid? removes the dependency on changed? entirely
    # -- nothing is ever attached until the assigned record has already been
    # found valid, no matter which validation is the one that fails.
    @news_post.assign_attributes(news_post_params)
    attach_body_images if @news_post.valid?

    if @news_post.save
      # Unconditional, with no published? gate: a wrong gate means a published
      # post that never purges, which is the 24-hour-stale bug this exists to
      # remove, while a needless purge costs a few origin re-renders. It also
      # covers the worst case for free -- setting published_at back to nil comes
      # through here, so a retracted post's page is purged like any other edit.
      enqueue_cache_purge(@news_post, also: urls_before)
      redirect_to news_post_path_for(@news_post), notice: "Post updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    # Computed BEFORE destroy!, unlike create and update: a deleted post cannot
    # be looked up, and its news_post_topics rows go with it
    # (dependent: :destroy), so nothing downstream could rebuild this list.
    urls = Services::News::CachedUrls.call(@news_post)
    domain = @news_post.domain
    @news_post.destroy!
    ::News::PurgeCachedPagesJob.perform_async(domain, urls)

    redirect_to news_posts_path_for, notice: "Post deleted."
  end

  # Server-rendered so the preview goes through the exact BodyRenderer the public
  # page uses and cannot drift from it. A client-side Markdown library is not an
  # option while admin and public share application.js -- it would be downloaded
  # by every visitor to every site to serve this one screen.
  def preview
    @preview_html = Services::News::BodyRenderer.call(params.dig(:news_post, :body))

    render :preview
  end

  private

  # Explicit, not a model callback: an after_commit making an external HTTP call
  # is invisible to its callers and would fire from the legacy-blog data
  # migration and from every test that creates a post. Both arguments are
  # JSON-native so they survive Sidekiq's serialisation unchanged.
  def enqueue_cache_purge(news_post, also: [])
    urls = (Services::News::CachedUrls.call(news_post) + also).uniq
    ::News::PurgeCachedPagesJob.perform_async(news_post.domain, urls)
  end

  # Always scoped, never a bare NewsPost.find: authenticate_admin! proves access
  # to the domain this controller is MOUNTED under, not that the id in the URL
  # belongs to it.
  def scope = NewsPost.where(domain: news_domain)

  def set_news_post
    @news_post = scope.friendly.find(params[:id])
  end

  def available_topics = NewsTopic.where(domain: news_domain).sorted_by_name
  helper_method :available_topics

  # Attached rather than mass-assigned: assigning to a has_many_attached replaces
  # the whole collection, so editing a post to add one screenshot would silently
  # drop every image already on it.
  def attach_body_images
    uploads = params.dig(:news_post, :body_images)
    return if uploads.blank?

    @news_post.body_images.attach(uploads.compact_blank)
  end

  def news_post_params
    permitted = params.require(:news_post).permit(
      :title, :body, :summary, :published_at, :share_image,
      news_topic_ids: []
    )

    # Topic ids arrive from a checkbox list, so a hand-crafted request could
    # name another domain's topic. Intersect with this domain's own rather
    # than trusting the submitted ids -- the join carries no domain of its
    # own to validate against.
    if permitted.key?(:news_topic_ids)
      permitted[:news_topic_ids] = available_topics
        .where(id: permitted[:news_topic_ids].compact_blank)
        .pluck(:id)
    end

    permitted
  end
end
