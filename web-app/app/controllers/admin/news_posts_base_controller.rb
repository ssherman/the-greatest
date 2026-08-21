# Domain-agnostic news post CRUD plus the Markdown preview. Each domain
# supplies a routable subclass filling in news_domain and the path helpers, and
# mixing in Admin::DomainScopedAuth itself. Mirrors Admin::ReviewsBaseController.
class Admin::NewsPostsBaseController < Admin::BaseController
  # :only lists here name only the actions this controller implements so far
  # (index, show) -- NOT the full set the finished controller will eventually
  # have. This app's test and development environments both set
  # config.action_controller.raise_on_missing_callback_actions = true (Rails
  # 7.1 default), which raises AbstractController::ActionNotFound on EVERY
  # request -- not just a request to the missing action -- the moment a
  # before_action's :only names an action the controller does not define.
  # Verified against this app: listing :create, :update, :destroy, :preview
  # and :edit here (as the plan's task text does, since it was written against
  # the FINISHED controller) 404s index and show too. Later tasks that add
  # those actions must add their names to these lists at the same time.
  before_action :require_domain_write!, only: []
  before_action :set_news_post, only: [:show]

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

  private

  # Always scoped, never a bare NewsPost.find: authenticate_admin! proves access
  # to the domain this controller is MOUNTED under, not that the id in the URL
  # belongs to it.
  def scope = NewsPost.where(domain: news_domain)

  def set_news_post
    @news_post = scope.friendly.find(params[:id])
  end
end
