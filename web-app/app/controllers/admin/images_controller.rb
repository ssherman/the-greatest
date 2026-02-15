class Admin::ImagesController < Admin::BaseController
  before_action :set_parent, only: [:index, :create]
  before_action :set_image, only: [:update, :destroy, :set_primary]

  def index
    @images = @parent.images.includes(file_attachment: :blob).order(primary: :desc, created_at: :desc)
    render layout: false
  end

  def create
    @image = @parent.images.build(image_params)

    if @image.save
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Image uploaded successfully."}}
            ),
            turbo_stream.replace(
              "images_list",
              template: "admin/images/index",
              locals: {parent: @parent, images: @parent.images.includes(file_attachment: :blob).order(primary: :desc, created_at: :desc)}
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "Image uploaded successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @image.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @image.errors.full_messages.join(", ")
        end
      end
    end
  end

  def update
    if @image.update(image_params.except(:file))
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Image updated successfully."}}
            ),
            turbo_stream.replace(
              "images_list",
              template: "admin/images/index",
              locals: {parent: @image.parent, images: @image.parent.images.includes(file_attachment: :blob).order(primary: :desc, created_at: :desc)}
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "Image updated successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @image.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @image.errors.full_messages.join(", ")
        end
      end
    end
  end

  def destroy
    parent = @image.parent
    @image.destroy!

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {notice: "Image deleted successfully."}}
          ),
          turbo_stream.replace(
            "images_list",
            template: "admin/images/index",
            locals: {parent: parent, images: parent.images.includes(file_attachment: :blob).order(primary: :desc, created_at: :desc)}
          )
        ]
      end
      format.html do
        redirect_to redirect_path_for_parent(parent), notice: "Image deleted successfully."
      end
    end
  end

  def set_primary
    @image.update!(primary: true)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {notice: "Primary image updated."}}
          ),
          turbo_stream.replace(
            "images_list",
            template: "admin/images/index",
            locals: {parent: @image.parent, images: @image.parent.images.includes(file_attachment: :blob).order(primary: :desc, created_at: :desc)}
          )
        ]
      end
      format.html do
        redirect_to redirect_path, notice: "Primary image updated."
      end
    end
  end

  private

  def set_parent
    @parent = if params[:artist_id]
      Music::Artist.find(params[:artist_id])
    elsif params[:album_id]
      Music::Album.find(params[:album_id])
    elsif params[:game_id]
      Games::Game.find(params[:game_id])
    elsif params[:company_id]
      Games::Company.find(params[:company_id])
    end
  end

  def set_image
    @image = Image.find(params[:id])
  end

  def image_params
    params.require(:image).permit(:file, :notes, :primary)
  end

  def redirect_path
    redirect_path_for_parent(@image&.parent || @parent)
  end

  def redirect_path_for_parent(parent)
    case parent.class.name
    when "Music::Artist"
      admin_artist_path(parent)
    when "Music::Album"
      admin_album_path(parent)
    when "Games::Game"
      admin_games_game_path(parent)
    when "Games::Company"
      admin_games_company_path(parent)
    else
      admin_root_path
    end
  end
end
