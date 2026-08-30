class Books::ReadingGoalsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :set_goal_and_cache_policy

  def show
    canonicalize_query_page
    return if performed?

    @progress = Services::Books::ReadingGoals::ProgressQuery.call(
      goal: @reading_goal,
      page: params[:page] || 1
    )
    @pagy = pagy_path_count(@progress.count, limit: Services::Books::ReadingGoals::ProgressQuery::PER_PAGE)
  end

  private

  def set_goal_and_cache_policy
    @reading_goal = Books::ReadingGoal.find(params[:id])
    if @reading_goal.public?
      cache_for_show_page
    else
      prevent_caching
      raise ActiveRecord::RecordNotFound unless Books::ReadingGoalPolicy.new(current_user, @reading_goal).show?
    end
  end

  def canonicalize_query_page
    return unless request.query_parameters.key?("page")

    raw = request.query_parameters["page"]
    raise ActiveRecord::RecordNotFound unless raw.is_a?(String) && raw.match?(/\A[1-9]\d*\z/)

    location = if raw.to_i == 1
      books_reading_goal_path(@reading_goal)
    else
      books_reading_goal_page_path(@reading_goal, raw.to_i)
    end
    redirect_to location, status: :moved_permanently
  end
end
