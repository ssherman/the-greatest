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
    @news_post = NewsPost.new(domain: news_domain, user: current_user)

    if save_post
      redirect_to news_post_path_for(@news_post), notice: "Post created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if save_post
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
  # page uses and cannot drift from it. A client-side Markdown library is not
  # worth it even though admin and public no longer share a bundle: it would
  # still be a second rendering path that could disagree with BodyRenderer, and
  # this way there is only one.
  def preview
    @preview_html = Services::News::BodyRenderer.call(params.dig(:news_post, :body))

    render :preview
  end

  private

  def save_post
    Services::News::SavePost.call(
      news_post: @news_post,
      attrs: news_post_params,
      body_images: params.dig(:news_post, :body_images) || []
    ).success?
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
