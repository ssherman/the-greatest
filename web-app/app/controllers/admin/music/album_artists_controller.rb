class Admin::Music::AlbumArtistsController < Admin::Music::BaseController
  before_action :set_album_artist, only: [:update, :destroy]
  before_action :set_parent_context, only: [:create]
  before_action :infer_context_from_album_artist, only: [:update, :destroy]

  def create
    @album_artist = Music::AlbumArtist.new(album_artist_params)

    if @album_artist.save
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Artist association added successfully."}}
            ),
            turbo_stream.replace(
              turbo_frame_id,
              partial: partial_path,
              locals: partial_locals
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "Artist association added successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @album_artist.errors.full_messages.join(", ")}}
          )
        end
        format.html do
          redirect_to redirect_path, alert: @album_artist.errors.full_messages.join(", ")
        end
      end
    end
  end

  def update
    if @album_artist.update(album_artist_params)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Position updated successfully."}}
            ),
            turbo_stream.replace(
              turbo_frame_id,
              partial: partial_path,
              locals: partial_locals
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "Position updated successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @album_artist.errors.full_messages.join(", ")}}
          )
        end
        format.html do
          redirect_to redirect_path, alert: @album_artist.errors.full_messages.join(", ")
        end
      end
    end
  end

  def destroy
    @album_artist.destroy!

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {notice: "Artist association removed successfully."}}
          ),
          turbo_stream.replace(
            turbo_frame_id,
            partial: partial_path,
            locals: partial_locals
          )
        ]
      end
      format.html do
        redirect_to redirect_path, notice: "Artist association removed successfully."
      end
    end
  end

  private

  def set_album_artist
    @album_artist = Music::AlbumArtist.find(params[:id])
  end

  def set_parent_context
    if params[:album_id].present?
      @album = Music::Album.find(params[:album_id])
      @context = :album
    elsif params[:artist_id].present?
      @artist = Music::Artist.find(params[:artist_id])
      @context = :artist
    end
  end

  def infer_context_from_album_artist
    @album = @album_artist.album
    @artist = @album_artist.artist

    # Determine context from the referer URL
    referer = request.referer || ""
    @context = if referer.include?("/admin/artists/")
      :artist
    else
      :album
    end
  end

  def album_artist_params
    params.require(:music_album_artist).permit(:album_id, :artist_id, :position)
  end

  def redirect_path
    if @context == :album
      admin_album_path(@album_artist.album)
    elsif @context == :artist
      admin_artist_path(@album_artist.artist)
    elsif @album_artist.album
      admin_album_path(@album_artist.album)
    elsif @album_artist.artist
      admin_artist_path(@album_artist.artist)
    else
      admin_root_path
    end
  end

  def turbo_frame_id
    (@context == :album) ? "album_artists_list" : "artist_albums_list"
  end

  def partial_path
    (@context == :album) ? "admin/music/albums/artists_list" : "admin/music/artists/albums_list"
  end

  def partial_locals
    if @context == :album
      {album: @album}
    else
      {artist: @artist}
    end
  end
end
