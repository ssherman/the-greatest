class Admin::Games::GameCompaniesController < Admin::Games::BaseController
  before_action :set_game_company, only: [:update, :destroy]

  def create
    @game = Games::Game.find(params[:game_id])
    authorize @game, :update?, policy_class: Games::GamePolicy

    @game_company = Games::GameCompany.new(game_company_params)

    if @game_company.save
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Company added successfully."}}
            ),
            turbo_stream.replace(
              "game_companies_list",
              partial: "admin/games/games/companies_list",
              locals: {game: @game}
            )
          ]
        end
        format.html do
          redirect_to admin_games_game_path(@game), notice: "Company added successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @game_company.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to admin_games_game_path(@game), alert: @game_company.errors.full_messages.join(", ")
        end
      end
    end
  end

  def update
    @game = @game_company.game
    authorize @game, :update?, policy_class: Games::GamePolicy

    if @game_company.update(game_company_params)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Company roles updated successfully."}}
            ),
            turbo_stream.replace(
              "game_companies_list",
              partial: "admin/games/games/companies_list",
              locals: {game: @game}
            )
          ]
        end
        format.html do
          redirect_to admin_games_game_path(@game), notice: "Company roles updated successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @game_company.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to admin_games_game_path(@game), alert: @game_company.errors.full_messages.join(", ")
        end
      end
    end
  end

  def destroy
    @game = @game_company.game
    authorize @game, :update?, policy_class: Games::GamePolicy
    @game_company.destroy!

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {notice: "Company removed successfully."}}
          ),
          turbo_stream.replace(
            "game_companies_list",
            partial: "admin/games/games/companies_list",
            locals: {game: @game}
          )
        ]
      end
      format.html do
        redirect_to admin_games_game_path(@game), notice: "Company removed successfully."
      end
    end
  end

  private

  def set_game_company
    @game_company = Games::GameCompany.find(params[:id])
  end

  def game_company_params
    params.require(:games_game_company).permit(:game_id, :company_id, :developer, :publisher)
  end
end
