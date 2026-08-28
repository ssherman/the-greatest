class Books::My::ReadingGoalsController < ApplicationController
  include Cacheable

  layout "books/application"

  before_action :require_signed_in!
  before_action :prevent_caching
  before_action :set_reading_goal, only: [:edit, :update, :destroy]

  def index
    today = Date.current
    goals = policy_scope(Books::ReadingGoal)
    @active_reading_goals = goals.active_on(today)
    @upcoming_reading_goals = goals.upcoming_on(today)
    @finished_reading_goals = goals.finished_on(today)
  end

  def new
    @reading_goal = default_goal
    authorize @reading_goal
  end

  def create
    @reading_goal = current_user.books_reading_goals.build(reading_goal_params)
    authorize @reading_goal
    save_goal
  end

  def edit
  end

  def update
    save_goal
  end

  def destroy
    result = Services::Books::ReadingGoals::DestroyGoal.call(goal: @reading_goal)
    if result.success?
      redirect_to books_my_reading_goals_path, notice: "Reading goal deleted."
    else
      redirect_to books_my_reading_goals_path, alert: result.errors.to_sentence
    end
  end

  private

  def set_reading_goal
    @reading_goal = policy_scope(Books::ReadingGoal).find(params[:id])
    authorize @reading_goal
  end

  def default_goal
    year = Date.current.year
    current_user.books_reading_goals.build(
      name: "My #{year} Reading Goal",
      description: "My yearly reading goal",
      target_count: 12,
      starts_on: Date.new(year, 1, 1),
      ends_on: Date.new(year, 12, 31),
      public: false
    )
  end

  def save_goal
    result = Services::Books::ReadingGoals::SaveGoal.call(goal: @reading_goal, attributes: reading_goal_params)
    if result.success?
      redirect_to books_my_reading_goals_path, notice: "Reading goal saved."
    elsif result.data[:persisted] && result.data[:purge_confirmed] == false
      redirect_to books_my_reading_goals_path,
        alert: "Reading goal is private at the origin, but edge cache purge confirmation failed."
    else
      form_action = if action_name == "create"
        :new
      else
        :edit
      end
      render form_action, status: :unprocessable_entity
    end
  end

  def reading_goal_params
    params.require(:reading_goal).permit(:name, :description, :target_count, :starts_on, :ends_on, :public)
  end
end
