class Admin::Music::AlbumsController < Admin::Music::BaseController
  before_action :set_album, only: [:show, :edit, :update, :destroy, :execute_action]
  before_action :authorize_album, only: [:show, :edit, :update, :destroy, :execute_action]

  def index
    authorize Music::Album
    load_albums_for_index
  end

  def show
    # @album loaded and authorized by before_action
    # Eager load associations for display
    @album = Music::Album
      .includes(
        :categories,
        :identifiers,
        :primary_image,
        :external_links,
        album_artists: [:artist],
        releases: {tracks: [:song]},
        images: {file_attachment: :blob},
        credits: [:artist]
      )
      .find(params[:id])
  end

  def new
    @album = Music::Album.new
    authorize @album
  end

  def create
    @album = Music::Album.new(album_params)
    authorize @album

    if @album.save
      redirect_to admin_album_path(@album), notice: "Album created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @album.update(album_params)
      redirect_to admin_album_path(@album), notice: "Album updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @album.destroy!
    redirect_to admin_albums_path, notice: "Album deleted successfully."
  end

  def execute_action
    fields_hash = params.except(:controller, :action, :id, :action_name, :album_ids)

    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(
      user: current_user,
      models: [@album],
      fields: fields_hash
    )

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "flash",
          partial: "admin/shared/flash",
          locals: {result: result}
        )
      end
      format.html { redirect_to admin_album_path(@album), notice: result.message }
    end
  end

  def bulk_action
    authorize Music::Album, :bulk_action?
    album_ids = params[:album_ids] || []
    albums = Music::Album.where(id: album_ids)

    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: albums)

    respond_to do |format|
      format.turbo_stream do
        load_albums_for_index

        render turbo_stream: [
          turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {result: result}),
          turbo_stream.replace("albums_table", partial: "admin/music/albums/table", locals: {albums: @albums, pagy: @pagy})
        ]
      end
      format.html { redirect_to admin_albums_path, notice: result.message }
    end
  end

  def search
    search_results = ::Search::Music::Search::AlbumAutocomplete.call(params[:q], size: 20)
    album_ids = search_results.map { |r| r[:id].to_i }

    # Filter out excluded ID (used for merge autocomplete to exclude current album)
    if params[:exclude_id].present?
      album_ids -= [params[:exclude_id].to_i]
    end

    if album_ids.empty?
      render json: []
      return
    end

    albums = Music::Album
      .where(id: album_ids)
      .includes(:artists)
      .in_order_of(:id, album_ids)

    render json: albums.map { |a|
      {
        value: a.id,
        text: "#{a.title} - #{a.artists.map(&:name).join(", ")}"
      }
    }
  end

  private

  def set_album
    @album = Music::Album.find(params[:id])
  end

  def authorize_album
    authorize @album
  end

  def load_albums_for_index
    if params[:q].present?
      search_results = ::Search::Music::Search::AlbumGeneral.call(params[:q], size: 1000)
      album_ids = search_results.map { |r| r[:id].to_i }

      @albums = if album_ids.empty?
        Music::Album.none
      else
        Music::Album
          .where(id: album_ids)
          .includes(:categories, album_artists: [:artist])
          .in_order_of(:id, album_ids)
      end
    else
      sort_column = sortable_column(params[:sort])

      @albums = Music::Album.all
        .includes(:categories, album_artists: [:artist])
        .order(sort_column)
    end

    @pagy, @albums = pagy(@albums, limit: 25)
  end

  def sortable_column(column)
    allowed_columns = {
      "id" => "music_albums.id",
      "title" => "music_albums.title",
      "release_year" => "music_albums.release_year",
      "created_at" => "music_albums.created_at"
    }

    allowed_columns.fetch(column, "music_albums.title")
  end

  def album_params
    params.require(:music_album).permit(
      :title,
      :description,
      :release_year
    )
  end
end
