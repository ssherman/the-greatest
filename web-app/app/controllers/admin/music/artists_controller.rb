class Admin::Music::ArtistsController < Admin::Music::BaseController
  before_action :set_artist, only: [:edit, :update, :destroy, :execute_action]

  def index
    load_artists_for_index
  end

  def show
    @artist = Music::Artist
      .includes(
        :categories,
        :identifiers,
        :primary_image,
        album_artists: {album: [:primary_image]},
        images: []
      )
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
        # Reload the full artist list to refresh the table
        load_artists_for_index

        render turbo_stream: [
          turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {result: result}),
          turbo_stream.replace("artists_table", partial: "admin/music/artists/table", locals: {artists: @artists, pagy: @pagy})
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
    search_results = ::Search::Music::Search::ArtistAutocomplete.call(params[:q], size: 10)
    artist_ids = search_results.map { |r| r[:id].to_i }

    # Guard against empty results - in_order_of raises ArgumentError with empty array
    if artist_ids.empty?
      render json: []
      return
    end

    # Load artist records preserving search order
    artists = Music::Artist
      .where(id: artist_ids)
      .in_order_of(:id, artist_ids)

    render json: artists.map { |a| {value: a.id, text: a.name} }
  end

  private

  def set_artist
    @artist = Music::Artist.find(params[:id])
  end

  def load_artists_for_index
    if params[:q].present?
      # Use OpenSearch for search
      search_results = ::Search::Music::Search::ArtistGeneral.call(params[:q], size: 1000)
      artist_ids = search_results.map { |r| r[:id].to_i }

      # Guard against empty results - in_order_of raises ArgumentError with empty array
      @artists = if artist_ids.empty?
        Music::Artist.none
      else
        # Preserve search order using Rails 8+ in_order_of
        Music::Artist
          .where(id: artist_ids)
          .includes(:categories)
          .left_joins(:albums)
          .select("music_artists.*, COUNT(DISTINCT music_albums.id) as albums_count")
          .group("music_artists.id")
          .in_order_of(:id, artist_ids)
      end
    else
      # Normal database query for browsing
      sort_column = sortable_column(params[:sort])

      @artists = Music::Artist.all
        .includes(:categories)
        .left_joins(:albums)
        .select("music_artists.*, COUNT(DISTINCT music_albums.id) as albums_count")
        .group("music_artists.id")
        .order(sort_column)
    end

    @pagy, @artists = pagy(@artists, items: 25)
  end

  def sortable_column(column)
    # Whitelist of allowed sort columns to prevent SQL injection
    allowed_columns = {
      "id" => "music_artists.id",
      "name" => "music_artists.name",
      "kind" => "music_artists.kind",
      "created_at" => "music_artists.created_at"
    }

    allowed_columns.fetch(column, "music_artists.name") # Default to name if invalid
  end

  def artist_params
    params.require(:music_artist).permit(
      :name, :description, :kind, :born_on, :year_died,
      :year_formed, :year_disbanded, :country
    )
  end
end
