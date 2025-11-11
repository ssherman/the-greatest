class Admin::Music::SongArtistsController < Admin::Music::BaseController
  before_action :set_song_artist, only: [:update, :destroy]
  before_action :set_parent_context, only: [:create]
  before_action :infer_context_from_song_artist, only: [:update, :destroy]

  def create
    @song_artist = Music::SongArtist.new(song_artist_params)

    if @song_artist.save
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
            locals: {flash: {error: @song_artist.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @song_artist.errors.full_messages.join(", ")
        end
      end
    end
  end

  def update
    if @song_artist.update(song_artist_params)
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
            locals: {flash: {error: @song_artist.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @song_artist.errors.full_messages.join(", ")
        end
      end
    end
  end

  def destroy
    @song_artist.destroy!

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

  def set_song_artist
    @song_artist = Music::SongArtist.find(params[:id])
  end

  def set_parent_context
    if params[:song_id].present?
      @song = Music::Song.find(params[:song_id])
      @context = :song
    elsif params[:artist_id].present?
      @artist = Music::Artist.find(params[:artist_id])
      @context = :artist
    end
  end

  def infer_context_from_song_artist
    @song = @song_artist.song
    @artist = @song_artist.artist

    referer = request.referer || ""
    @context = if referer.include?("/admin/artists/")
      :artist
    else
      :song
    end
  end

  def song_artist_params
    params.require(:music_song_artist).permit(:song_id, :artist_id, :position)
  end

  def redirect_path
    if @context == :song
      admin_song_path(@song_artist.song)
    elsif @context == :artist
      admin_artist_path(@song_artist.artist)
    elsif @song_artist.song
      admin_song_path(@song_artist.song)
    elsif @song_artist.artist
      admin_artist_path(@song_artist.artist)
    else
      admin_root_path
    end
  end

  def turbo_frame_id
    (@context == :song) ? "song_artists_list" : "artist_songs_list"
  end

  def partial_path
    (@context == :song) ? "admin/music/songs/artists_list" : "admin/music/artists/songs_list"
  end

  def partial_locals
    if @context == :song
      {song: @song}
    else
      {artist: @artist}
    end
  end
end
