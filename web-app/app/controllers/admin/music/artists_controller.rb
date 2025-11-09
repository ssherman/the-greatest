class Admin::Music::ArtistsController < Admin::Music::BaseController
  before_action :set_artist, only: [:edit, :update, :destroy, :execute_action]

  def index
    if params[:q].present?
      # Use OpenSearch for search
      search_results = ::Search::Music::Search::ArtistGeneral.call(params[:q], size: 1000)
      artist_ids = search_results.map { |r| r[:id].to_i }

      # Preserve search order using Rails 7+ in_order_of
      @artists = Music::Artist
        .includes(:categories)
        .left_joins(:albums)
        .select("music_artists.*, COUNT(DISTINCT music_albums.id) as albums_count")
        .group("music_artists.id")
        .in_order_of(:id, artist_ids)
    else
      # Normal database query for browsing
      sort_column = (params[:sort] == "id") ? "music_artists.id" : (params[:sort] || "music_artists.name")

      @artists = Music::Artist.all
        .includes(:categories)
        .left_joins(:albums)
        .select("music_artists.*, COUNT(DISTINCT music_albums.id) as albums_count")
        .group("music_artists.id")
        .order(sort_column)
    end

    @pagy, @artists = pagy(@artists, items: 25)
  end

  def show
    @artist = Music::Artist
      .includes(:categories, :identifiers, :primary_image, albums: [:primary_image], images: [])
      .find(params[:id])
  end

  def new
    @artist = Music::Artist.new
  end

  def create
    @artist = Music::Artist.new(artist_params)

    if @artist.save
      redirect_to admin_artist_path(@artist), notice: "Artist created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    # @artist loaded by before_action
  end

  def update
    if @artist.update(artist_params)
      redirect_to admin_artist_path(@artist), notice: "Artist updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @artist.destroy!
    redirect_to admin_artists_path, notice: "Artist deleted successfully."
  end

  def execute_action
    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: [@artist])

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "flash",
          partial: "admin/shared/flash",
          locals: {result: result}
        )
      end
      format.html { redirect_to admin_artist_path(@artist), notice: result.message }
    end
  end

  def bulk_action
    artist_ids = params[:artist_ids] || []
    artists = Music::Artist.where(id: artist_ids)

    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: artists)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {result: result}),
          turbo_stream.replace("artists_table", partial: "admin/music/artists/table", locals: {artists: @artists})
        ]
      end
      format.html { redirect_to admin_artists_path, notice: result.message }
    end
  end

  def index_action
    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: [])

    redirect_to admin_artists_path, notice: result.message
  end

  def search
    # Use existing OpenSearch implementation
    search_results = ::Search::Music::Search::ArtistGeneral.call(params[:q], size: 10)
    artist_ids = search_results.map { |r| r[:id].to_i }

    # Load artist records preserving search order
    artists = Music::Artist.in_order_of(:id, artist_ids)

    render json: artists.map { |a| {value: a.id, text: a.name} }
  end

  private

  def set_artist
    @artist = Music::Artist.find(params[:id])
  end

  def artist_params
    params.require(:music_artist).permit(
      :name, :description, :kind, :born_on, :year_died,
      :year_formed, :year_disbanded, :country
    )
  end
end
