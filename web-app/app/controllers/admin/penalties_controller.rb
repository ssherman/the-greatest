class Admin::PenaltiesController < Admin::BaseController
  layout "music/admin"
  before_action :set_penalty, only: [:show, :edit, :update, :destroy]

  def index
    @penalties = Penalty
      .includes(:user, :penalty_applications, :list_penalties)
      .then { |scope| apply_type_filter(scope) }
      .order(:name)

    @pagy, @penalties = pagy(@penalties, items: 25)
    @selected_type = params[:type] || "All"
  end

  def show
    @penalty = Penalty
      .includes(:user, :penalty_applications, :list_penalties)
      .find(params[:id])
  end

  def new
    @penalty = Penalty.new
  end

  def create
    penalty_class = get_penalty_class(params[:penalty][:type])
    @penalty = penalty_class.new(create_penalty_params)

    if @penalty.save
      redirect_to admin_penalty_path(@penalty), notice: "Penalty created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @penalty.update(penalty_params)
      redirect_to admin_penalty_path(@penalty), notice: "Penalty updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @penalty.destroy!
    redirect_to admin_penalties_path, notice: "Penalty deleted successfully."
  end

  private

  def set_penalty
    @penalty = Penalty.find(params[:id])
  end

  def apply_type_filter(scope)
    return scope if params[:type].blank? || params[:type] == "All"

    type_class = "#{params[:type]}::Penalty"
    scope.where(type: type_class)
  end

  def get_penalty_class(type_string)
    case type_string
    when "Global::Penalty"
      Global::Penalty
    when "Music::Penalty"
      Music::Penalty
    when "Books::Penalty"
      Books::Penalty
    when "Movies::Penalty"
      Movies::Penalty
    when "Games::Penalty"
      Games::Penalty
    else
      Global::Penalty
    end
  end

  def create_penalty_params
    params.require(:penalty).permit(:name, :description, :dynamic_type)
  end

  def penalty_params
    param_key = @penalty.type.underscore.tr("/", "_").to_sym
    params.require(param_key).permit(:name, :description, :dynamic_type)
  end
end
