# Domain-agnostic topic CRUD. Each domain supplies a routable subclass that
# fills in news_domain and the path helpers and mixes in
# Admin::DomainScopedAuth itself, because admin auth is domain-scoped through
# that concern. Mirrors Admin::ReviewsBaseController.
#
# Path helper methods are named *_for rather than matching the route helper
# names: a private method named admin_books_news_topics_path would shadow the
# real helper in the views this controller renders.
class Admin::NewsTopicsBaseController < Admin::BaseController
  before_action :require_domain_write!, only: [:new, :create, :edit, :update, :destroy]
  before_action :require_domain_delete!, only: [:destroy]
  before_action :set_news_topic, only: [:edit, :update, :destroy]

  helper_method :news_topics_path_for, :news_topic_path_for, :new_news_topic_path_for,
    :edit_news_topic_path_for

  def index
    @news_topics = scope.sorted_by_name
  end

  def new
    @news_topic = NewsTopic.new(domain: news_domain)
  end

  def create
    @news_topic = NewsTopic.new(news_topic_params.merge(domain: news_domain))

    if @news_topic.save
      redirect_to news_topics_path_for, notice: "Topic created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @news_topic.update(news_topic_params)
      redirect_to news_topics_path_for, notice: "Topic updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @news_topic.destroy!
    redirect_to news_topics_path_for, notice: "Topic deleted."
  end

  private

  # Always scoped, never a bare NewsTopic.find: authenticate_admin! only proves
  # access to the domain this controller is MOUNTED under, and says nothing
  # about which domain the id in the URL belongs to.
  def scope = NewsTopic.where(domain: news_domain)

  def set_news_topic
    @news_topic = scope.friendly.find(params[:id])
  end

  def news_topic_params
    params.require(:news_topic).permit(:name)
  end
end
