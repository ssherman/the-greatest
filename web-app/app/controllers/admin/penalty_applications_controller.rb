class Admin::PenaltyApplicationsController < Admin::BaseController
  before_action :set_ranking_configuration, only: [:index, :create]
  before_action :set_penalty_application, only: [:update, :destroy]

  def index
    @penalty_applications = @ranking_configuration.penalty_applications.includes(:penalty).order("penalties.name")
    render layout: false
  end

  def create
    @penalty_application = @ranking_configuration.penalty_applications.build(create_penalty_application_params)

    if @penalty_application.save
      @ranking_configuration.reload
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Penalty attached successfully."}}
            ),
            turbo_stream.replace(
              "penalty_applications_list",
              template: "admin/penalty_applications/index",
              locals: {ranking_configuration: @ranking_configuration, penalty_applications: @ranking_configuration.penalty_applications.includes(:penalty).order("penalties.name")}
            ),
            turbo_stream.replace(
              "add_penalty_to_configuration_modal",
              Admin::AddPenaltyToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration)
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "Penalty attached successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @penalty_application.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @penalty_application.errors.full_messages.join(", ")
        end
      end
    end
  end

  def update
    @ranking_configuration = @penalty_application.ranking_configuration

    if @penalty_application.update(update_penalty_application_params)
      @ranking_configuration.reload
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Penalty application updated successfully."}}
            ),
            turbo_stream.replace(
              "penalty_applications_list",
              template: "admin/penalty_applications/index",
              locals: {ranking_configuration: @ranking_configuration, penalty_applications: @ranking_configuration.penalty_applications.includes(:penalty).order("penalties.name")}
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "Penalty application updated successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @penalty_application.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @penalty_application.errors.full_messages.join(", ")
        end
      end
    end
  end

  def destroy
    @ranking_configuration = @penalty_application.ranking_configuration
    @penalty_application.destroy!
    @ranking_configuration.reload

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {notice: "Penalty detached successfully."}}
          ),
          turbo_stream.replace(
            "penalty_applications_list",
            template: "admin/penalty_applications/index",
            locals: {ranking_configuration: @ranking_configuration, penalty_applications: @ranking_configuration.penalty_applications.includes(:penalty).order("penalties.name")}
          ),
          turbo_stream.replace(
            "add_penalty_to_configuration_modal",
            Admin::AddPenaltyToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration)
          )
        ]
      end
      format.html do
        redirect_to redirect_path, notice: "Penalty detached successfully."
      end
    end
  end

  private

  def set_ranking_configuration
    @ranking_configuration = RankingConfiguration.find(params[:ranking_configuration_id])
  end

  def set_penalty_application
    @penalty_application = PenaltyApplication.find(params[:id])
  end

  def create_penalty_application_params
    params.require(:penalty_application).permit(:penalty_id, :value)
  end

  def update_penalty_application_params
    params.require(:penalty_application).permit(:value)
  end

  def redirect_path
    case @ranking_configuration.type
    when /^Music::Albums::/
      admin_albums_ranking_configuration_path(@ranking_configuration)
    when /^Music::Songs::/
      admin_songs_ranking_configuration_path(@ranking_configuration)
    else
      music_root_path
    end
  end
end
