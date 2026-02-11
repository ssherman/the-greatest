class Admin::Games::GamesController < Admin::Games::BaseController
  before_action :set_game, only: [:show, :edit, :update, :destroy]
  before_action :authorize_game, only: [:show, :edit, :update, :destroy]

  def index
    authorize Games::Game
    load_games_for_index
  end

  def show
    @game = Games::Game
      .includes(
        :categories,
        :identifiers,
        :primary_image,
        :series,
        :parent_game,
        :child_games,
        game_companies: [:company],
        game_platforms: [:platform],
        images: {file_attachment: :blob}
      )
      .find(params[:id])
  end

  def new
    @game = Games::Game.new
    authorize @game
  end

  def create
    @game = Games::Game.new(game_params)
    authorize @game

    if @game.save
      redirect_to admin_games_game_path(@game), notice: "Game created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @game.update(game_params)
      redirect_to admin_games_game_path(@game), notice: "Game updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @game.destroy!
    redirect_to admin_games_games_path, notice: "Game deleted successfully."
  end

  def search
    search_results = ::Search::Games::Search::GameAutocomplete.call(params[:q], size: 20)
    game_ids = search_results.map { |r| r[:id].to_i }

    if game_ids.empty?
      render json: []
      return
    end

    games = Games::Game
      .where(id: game_ids)
      .in_order_of(:id, game_ids)

    render json: games.map { |g| {value: g.id, text: "#{g.title}#{" (#{g.release_year})" if g.release_year.present?}"} }
  end

  private

  def set_game
    @game = Games::Game.find(params[:id])
  end

  def authorize_game
    authorize @game
  end

  def load_games_for_index
    if params[:q].present?
      search_results = ::Search::Games::Search::GameGeneral.call(params[:q], size: 1000)
      game_ids = search_results.map { |r| r[:id].to_i }

      @games = if game_ids.empty?
        Games::Game.none
      else
        Games::Game
          .where(id: game_ids)
          .includes(:companies, :platforms)
          .in_order_of(:id, game_ids)
      end
    else
      sort_column = sortable_column(params[:sort])

      @games = Games::Game.all
        .includes(:companies, :platforms)
        .order(sort_column)
    end

    @pagy, @games = pagy(@games, limit: 25)
  end

  def sortable_column(column)
    allowed_columns = {
      "id" => "games_games.id",
      "title" => "games_games.title",
      "release_year" => "games_games.release_year",
      "game_type" => "games_games.game_type",
      "created_at" => "games_games.created_at"
    }

    allowed_columns.fetch(column, "games_games.title")
  end

  def game_params
    params.require(:games_game).permit(
      :title, :description, :release_year, :game_type,
      :parent_game_id, :series_id
    )
  end
end
