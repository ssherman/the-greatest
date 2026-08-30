class Books::ReadingGoalStateController < ApplicationController
  include Cacheable

  before_action :prevent_caching
  before_action :require_signed_in!

  def show
    goal = Books::ReadingGoal.find(params[:id])
    policy = Books::ReadingGoalPolicy.new(current_user, goal)
    raise ActiveRecord::RecordNotFound unless goal.public? || policy.show?

    render json: {
      can_manage: policy.update?,
      manage_url: edit_books_my_reading_goal_path(goal)
    }
  end
end
