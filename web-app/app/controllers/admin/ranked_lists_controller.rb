class Admin::RankedListsController < Admin::BaseController
  layout "music/admin", only: [:show]

  before_action :set_ranking_configuration, only: [:index, :create]
  before_action :set_ranked_list, only: [:show, :destroy]

  def index
    @ranked_lists = @ranking_configuration.ranked_lists
      .includes(list: :submitted_by)
      .order(weight: :desc)

    @pagy, @ranked_lists = pagy(@ranked_lists, limit: 25)

    render layout: false
  end

  def show
    @ranked_list = RankedList.includes(:ranking_configuration, list: :submitted_by).find(params[:id])
  end

  def create
    @ranked_list = @ranking_configuration.ranked_lists.build(ranked_list_params)

    if @ranked_list.save
      @ranking_configuration.reload
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "List added successfully."}}
            ),
            turbo_stream.replace(
              "ranked_lists_list",
              template: "admin/ranked_lists/index",
              locals: {ranking_configuration: @ranking_configuration, ranked_lists: @ranking_configuration.ranked_lists.includes(list: :submitted_by).order(weight: :desc)}
            ),
            turbo_stream.replace(
              "add_list_to_configuration_modal",
              Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration)
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "List added successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @ranked_list.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @ranked_list.errors.full_messages.join(", ")
        end
      end
    end
  end

  def destroy
    @ranking_configuration = @ranked_list.ranking_configuration
    @ranked_list.destroy!
    @ranking_configuration.reload

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {notice: "List removed successfully."}}
          ),
          turbo_stream.replace(
            "ranked_lists_list",
            template: "admin/ranked_lists/index",
            locals: {ranking_configuration: @ranking_configuration, ranked_lists: @ranking_configuration.ranked_lists.includes(list: :submitted_by).order(weight: :desc)}
          ),
          turbo_stream.replace(
            "add_list_to_configuration_modal",
            Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration)
          )
        ]
      end
      format.html do
        redirect_to redirect_path, notice: "List removed successfully."
      end
    end
  end

  private

  def set_ranking_configuration
    @ranking_configuration = RankingConfiguration.find(params[:ranking_configuration_id])
  end

  def set_ranked_list
    @ranked_list = RankedList.find(params[:id])
  end

  def ranked_list_params
    params.require(:ranked_list).permit(:list_id)
  end

  def redirect_path
    case @ranking_configuration.type
    when /^Music::Albums::/
      admin_albums_ranking_configuration_path(@ranking_configuration)
    when /^Music::Songs::/
      admin_songs_ranking_configuration_path(@ranking_configuration)
    when /^Games::/
      admin_games_ranking_configuration_path(@ranking_configuration)
    else
      music_root_path
    end
  end
end
