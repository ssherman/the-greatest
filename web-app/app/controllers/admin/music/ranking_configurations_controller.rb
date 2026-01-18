class Admin::Music::RankingConfigurationsController < Admin::Music::BaseController
  before_action :set_ranking_configuration, only: [:show, :edit, :update, :destroy, :execute_action]
  before_action :authorize_ranking_configuration, only: [:show, :edit, :update, :destroy, :execute_action]

  def index
    authorize ranking_configuration_class, policy_class: Music::RankingConfigurationPolicy
    load_ranking_configurations_for_index
  end

  def show
    @ranking_configuration = ranking_configuration_class
      .includes(:primary_mapped_list, :secondary_mapped_list, penalty_applications: :penalty, ranked_lists: {list: :submitted_by})
      .find(params[:id])
  end

  def new
    @ranking_configuration = ranking_configuration_class.new
    authorize @ranking_configuration, policy_class: Music::RankingConfigurationPolicy
  end

  def create
    @ranking_configuration = ranking_configuration_class.new(ranking_configuration_params)
    authorize @ranking_configuration, policy_class: Music::RankingConfigurationPolicy

    if @ranking_configuration.save
      redirect_to ranking_configuration_path(@ranking_configuration), notice: "Ranking configuration created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @ranking_configuration.update(ranking_configuration_params)
      redirect_to ranking_configuration_path(@ranking_configuration), notice: "Ranking configuration updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @ranking_configuration.destroy!
    redirect_to ranking_configurations_path, notice: "Ranking configuration deleted successfully."
  end

  def execute_action
    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: [@ranking_configuration])

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "flash",
          partial: "admin/shared/flash",
          locals: {result: result}
        )
      end
      format.html { redirect_to ranking_configuration_path(@ranking_configuration), notice: result.message }
    end
  end

  def index_action
    authorize ranking_configuration_class, :index_action?, policy_class: Music::RankingConfigurationPolicy
    ranking_configuration_ids = params[:ranking_configuration_ids] || []

    # If no IDs provided, use all configurations of this type
    ranking_configurations = if ranking_configuration_ids.empty?
      ranking_configuration_class.all
    else
      ranking_configuration_class.where(id: ranking_configuration_ids)
    end

    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: ranking_configurations)

    respond_to do |format|
      format.turbo_stream do
        load_ranking_configurations_for_index

        render turbo_stream: [
          turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {result: result}),
          turbo_stream.replace("ranking_configurations_table", partial: table_partial_path, locals: {ranking_configurations: @ranking_configurations, pagy: @pagy})
        ]
      end
      format.html { redirect_to ranking_configurations_path, notice: result.message }
    end
  end

  private

  def set_ranking_configuration
    @ranking_configuration = ranking_configuration_class.find(params[:id])
  end

  def authorize_ranking_configuration
    authorize @ranking_configuration, policy_class: Music::RankingConfigurationPolicy
  end

  def load_ranking_configurations_for_index
    if params[:q].present?
      @ranking_configurations = ranking_configuration_class
        .where("name ILIKE ?", "%#{params[:q]}%")
    else
      sort_column = sortable_column(params[:sort])

      @ranking_configurations = ranking_configuration_class.all
        .order(sort_column)
    end

    @pagy, @ranking_configurations = pagy(@ranking_configurations, limit: 25)
  end

  def sortable_column(column)
    allowed_columns = {
      "id" => "ranking_configurations.id",
      "name" => "ranking_configurations.name",
      "algorithm_version" => "ranking_configurations.algorithm_version",
      "published_at" => "ranking_configurations.published_at",
      "created_at" => "ranking_configurations.created_at"
    }

    allowed_columns.fetch(column.to_s, "ranking_configurations.name")
  end

  def ranking_configuration_params
    params.require(:ranking_configuration).permit(
      :name,
      :description,
      :global,
      :primary,
      :archived,
      :published_at,
      :algorithm_version,
      :exponent,
      :bonus_pool_percentage,
      :min_list_weight,
      :list_limit,
      :apply_list_dates_penalty,
      :max_list_dates_penalty_age,
      :max_list_dates_penalty_percentage,
      :primary_mapped_list_id,
      :secondary_mapped_list_id,
      :primary_mapped_list_cutoff_limit
    )
  end

  def ranking_configuration_class
    raise NotImplementedError, "Subclass must implement ranking_configuration_class"
  end

  def ranking_configurations_path
    raise NotImplementedError, "Subclass must implement ranking_configurations_path"
  end

  def ranking_configuration_path(config)
    raise NotImplementedError, "Subclass must implement ranking_configuration_path"
  end

  def table_partial_path
    raise NotImplementedError, "Subclass must implement table_partial_path"
  end
end
