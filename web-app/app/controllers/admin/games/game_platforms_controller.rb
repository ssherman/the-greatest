class Admin::Games::GamePlatformsController < Admin::Games::BaseController
  before_action :set_game_platform, only: [:destroy]

  def create
    @game = Games::Game.find(params[:game_id])
    authorize @game, :update?, policy_class: Games::GamePolicy

    @game_platform = Games::GamePlatform.new(game_platform_params)

    if @game_platform.save
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Platform added successfully."}}
            ),
            turbo_stream.replace(
              "game_platforms_list",
              partial: "admin/games/games/platforms_list",
              locals: {game: @game}
            )
          ]
        end
        format.html do
          redirect_to admin_games_game_path(@game), notice: "Platform added successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @game_platform.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to admin_games_game_path(@game), alert: @game_platform.errors.full_messages.join(", ")
        end
      end
    end
  end

  def destroy
    @game = @game_platform.game
    authorize @game, :update?, policy_class: Games::GamePolicy
    @game_platform.destroy!

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {notice: "Platform removed successfully."}}
          ),
          turbo_stream.replace(
            "game_platforms_list",
            partial: "admin/games/games/platforms_list",
            locals: {game: @game}
          )
        ]
      end
      format.html do
        redirect_to admin_games_game_path(@game), notice: "Platform removed successfully."
      end
    end
  end

  private

  def set_game_platform
    @game_platform = Games::GamePlatform.find(params[:id])
  end

  def game_platform_params
    params.require(:games_game_platform).permit(:game_id, :platform_id)
  end
end
