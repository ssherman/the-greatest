# frozen_string_literal: true

# Shared actions for managing artist associations (album_artists, song_artists).
# Both controllers are ~95% identical — differences are confined to model class,
# param key, parent resource name, policy class, frame IDs, and partial paths.
#
# Subclasses must implement:
#   - join_model_class       → Music::AlbumArtist or Music::SongArtist
#   - param_key              → :music_album_artist or :music_song_artist
#   - parent_resource_name   → :album or :song
#   - parent_policy_class    → Music::AlbumPolicy or Music::SongPolicy
#   - parent_path(resource)  → admin_album_path or admin_song_path
#   - parent_frame_id        → "album_artists_list" or "song_artists_list"
#   - artist_frame_id        → "artist_albums_list" or "artist_songs_list"
#   - parent_partial_path    → "admin/music/albums/artists_list"
#   - artist_partial_path    → "admin/music/artists/albums_list" or "admin/music/artists/songs_list"
module ArtistAssociationActions
  extend ActiveSupport::Concern

  included do
    before_action :set_association, only: [:update, :destroy]
    before_action :set_parent_context, only: [:create]
    before_action :infer_context_from_association, only: [:update, :destroy]
  end

  def create
    @association = join_model_class.new(association_params)
    parent = instance_variable_get(:"@#{parent_resource_name}") || @association.public_send(parent_resource_name)
    authorize parent, :update?, policy_class: parent_policy_class

    if @association.save
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
            locals: {flash: {error: @association.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @association.errors.full_messages.join(", ")
        end
      end
    end
  end

  def update
    authorize @association.public_send(parent_resource_name), :update?, policy_class: parent_policy_class

    if @association.update(association_params)
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
            locals: {flash: {error: @association.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @association.errors.full_messages.join(", ")
        end
      end
    end
  end

  def destroy
    authorize @association.public_send(parent_resource_name), :update?, policy_class: parent_policy_class
    @association.destroy!

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

  def set_association
    @association = join_model_class.find(params[:id])
  end

  def set_parent_context
    if params[:"#{parent_resource_name}_id"].present?
      parent_model = "Music::#{parent_resource_name.to_s.classify}".constantize
      instance_variable_set(:"@#{parent_resource_name}", parent_model.find(params[:"#{parent_resource_name}_id"]))
      @context = parent_resource_name
    elsif params[:artist_id].present?
      @artist = Music::Artist.find(params[:artist_id])
      @context = :artist
    end
  end

  def infer_context_from_association
    parent = @association.public_send(parent_resource_name)
    instance_variable_set(:"@#{parent_resource_name}", parent)
    @artist = @association.artist

    referer = request.referer || ""
    @context = if referer.include?("/admin/artists/")
      :artist
    else
      parent_resource_name
    end
  end

  def association_params
    params.require(param_key).permit(:"#{parent_resource_name}_id", :artist_id, :position)
  end

  def redirect_path
    if @context == parent_resource_name
      parent_path(@association.public_send(parent_resource_name))
    elsif @context == :artist
      admin_artist_path(@association.artist)
    elsif @association.public_send(parent_resource_name)
      parent_path(@association.public_send(parent_resource_name))
    elsif @association.artist
      admin_artist_path(@association.artist)
    else
      admin_root_path
    end
  end

  def turbo_frame_id
    (@context == parent_resource_name) ? parent_frame_id : artist_frame_id
  end

  def partial_path
    (@context == parent_resource_name) ? parent_partial_path : artist_partial_path
  end

  def partial_locals
    if @context == parent_resource_name
      {parent_resource_name => instance_variable_get(:"@#{parent_resource_name}")}
    else
      {artist: @artist}
    end
  end

  # Abstract methods - subclasses must implement

  def join_model_class
    raise NotImplementedError, "Subclass must implement #join_model_class"
  end

  def param_key
    raise NotImplementedError, "Subclass must implement #param_key"
  end

  def parent_resource_name
    raise NotImplementedError, "Subclass must implement #parent_resource_name"
  end

  def parent_policy_class
    raise NotImplementedError, "Subclass must implement #parent_policy_class"
  end

  def parent_path(resource)
    raise NotImplementedError, "Subclass must implement #parent_path"
  end

  def parent_frame_id
    raise NotImplementedError, "Subclass must implement #parent_frame_id"
  end

  def artist_frame_id
    raise NotImplementedError, "Subclass must implement #artist_frame_id"
  end

  def parent_partial_path
    raise NotImplementedError, "Subclass must implement #parent_partial_path"
  end

  def artist_partial_path
    raise NotImplementedError, "Subclass must implement #artist_partial_path"
  end
end
