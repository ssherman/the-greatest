class Admin::Music::SongsController < Admin::Music::BaseController
  before_action :set_song, only: [:show, :edit, :update, :destroy, :execute_action]

  def index
    load_songs_for_index
  end

  def show
    @song = Music::Song
      .includes(
        :categories,
        :identifiers,
        :external_links,
        song_artists: [:artist],
        tracks: {release: [:album, :primary_image]},
        list_items: [:list],
        ranked_items: [:ranking_configuration]
      )
      .find(params[:id])
  end

  def new
    @song = Music::Song.new
  end

  def create
    @song = Music::Song.new(song_params)

    if @song.save
      redirect_to admin_song_path(@song), notice: "Song created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @song.update(song_params)
      redirect_to admin_song_path(@song), notice: "Song updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @song.destroy!
    redirect_to admin_songs_path, notice: "Song deleted successfully."
  end

  def execute_action
    fields_hash = params.except(:controller, :action, :id, :action_name, :song_ids)

    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(
      user: current_user,
      models: [@song],
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
      format.html { redirect_to admin_song_path(@song), notice: result.message }
    end
  end

  def bulk_action
    song_ids = params[:song_ids] || []
    songs = Music::Song.where(id: song_ids)

    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: songs)

    load_songs_for_index

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {result: result}),
          turbo_stream.replace("songs_table", partial: "admin/music/songs/table", locals: {songs: @songs, pagy: @pagy})
        ]
      end
      format.html { redirect_to admin_songs_path, notice: result.message }
    end
  end

  def search
    search_results = ::Search::Music::Search::SongAutocomplete.call(params[:q], size: 10)
    song_ids = search_results.map { |r| r[:id].to_i }

    if song_ids.empty?
      render json: []
      return
    end

    songs = Music::Song
      .where(id: song_ids)
      .includes(:artists)
      .in_order_of(:id, song_ids)

    render json: songs.map { |s|
      {
        value: s.id,
        text: "#{s.title} - #{s.artists.map(&:name).join(", ")}"
      }
    }
  end

  private

  def set_song
    @song = Music::Song.find(params[:id])
  end

  def load_songs_for_index
    if params[:q].present?
      search_results = ::Search::Music::Search::SongGeneral.call(params[:q], size: 1000)
      song_ids = search_results.map { |r| r[:id].to_i }

      @songs = if song_ids.empty?
        Music::Song.none
      else
        Music::Song
          .where(id: song_ids)
          .includes(:categories, song_artists: [:artist])
          .in_order_of(:id, song_ids)
      end
    else
      sort_column = sortable_column(params[:sort])

      @songs = Music::Song.all
        .includes(:categories, song_artists: [:artist])
        .order(sort_column)
    end

    @pagy, @songs = pagy(@songs, items: 25)
  end

  def sortable_column(column)
    allowed_columns = {
      "id" => "music_songs.id",
      "title" => "music_songs.title",
      "release_year" => "music_songs.release_year",
      "duration_secs" => "music_songs.duration_secs",
      "created_at" => "music_songs.created_at"
    }

    allowed_columns.fetch(column.to_s, "music_songs.title")
  end

  def song_params
    params.require(:music_song).permit(
      :title,
      :description,
      :notes,
      :duration_secs,
      :release_year,
      :isrc
    )
  end
end
