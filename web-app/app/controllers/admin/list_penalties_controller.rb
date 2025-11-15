class Admin::ListPenaltiesController < Admin::BaseController
  before_action :set_list, only: [:index, :create]
  before_action :set_list_penalty, only: [:destroy]

  def index
    @list_penalties = @list.list_penalties.includes(:penalty).order("penalties.name")
    render layout: false
  end

  def create
    @list_penalty = @list.list_penalties.build(list_penalty_params)

    if @list_penalty.save
      @list.reload
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Penalty attached successfully."}}
            ),
            turbo_stream.replace(
              "list_penalties_list",
              template: "admin/list_penalties/index",
              locals: {list: @list, list_penalties: @list.list_penalties.includes(:penalty).order("penalties.name")}
            ),
            turbo_stream.replace(
              "attach_penalty_modal",
              Admin::AttachPenaltyModalComponent.new(list: @list)
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "Penalty attached successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @list_penalty.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @list_penalty.errors.full_messages.join(", ")
        end
      end
    end
  end

  def destroy
    @list = @list_penalty.list
    @list_penalty.destroy!
    @list.reload

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {notice: "Penalty detached successfully."}}
          ),
          turbo_stream.replace(
            "list_penalties_list",
            template: "admin/list_penalties/index",
            locals: {list: @list, list_penalties: @list.list_penalties.includes(:penalty).order("penalties.name")}
          ),
          turbo_stream.replace(
            "attach_penalty_modal",
            Admin::AttachPenaltyModalComponent.new(list: @list)
          )
        ]
      end
      format.html do
        redirect_to redirect_path, notice: "Penalty detached successfully."
      end
    end
  end

  private

  def set_list
    @list = List.find(params[:list_id])
  end

  def set_list_penalty
    @list_penalty = ListPenalty.find(params[:id])
  end

  def list_penalty_params
    params.require(:list_penalty).permit(:penalty_id)
  end

  def redirect_path
    case @list.type
    when /^Music::Albums::/
      admin_albums_list_path(@list)
    when /^Music::Songs::/
      admin_songs_list_path(@list)
    else
      music_root_path
    end
  end
end
