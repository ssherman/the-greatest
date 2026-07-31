class Admin::DescriptionsController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :require_domain_write!, only: [:create, :update, :destroy, :set_preferred]
  before_action :set_parent, only: [:index, :create]
  before_action :set_description, only: [:update, :destroy, :set_preferred]

  def index
    @descriptions = @parent.descriptions.order(rank: :desc, source: :asc)
    render layout: false
  end

  def create
    @description = @parent.descriptions.build(description_params)
    @description.kind = :summary
    @description.locale = "en"
    @description.rank = :normal

    if @description.save
      respond_with_list(@parent, notice: "Description added.")
    else
      respond_with_error(@description)
    end
  end

  def update
    if @description.update(description_params)
      respond_with_list(@description.describable, notice: "Description updated.")
    else
      respond_with_error(@description)
    end
  end

  def destroy
    describable = @description.describable
    @description.destroy!
    respond_with_list(describable, notice: "Description deleted.")
  end

  # Demote-then-promote in a transaction. This cannot mirror Image's after_save
  # promote-first callback: the partial unique index index_descriptions_one_preferred_per_key
  # rejects two preferred rows for the same (describable, kind, locale) mid-callback.
  def set_preferred
    Description.transaction do
      Description
        .where(describable_type: @description.describable_type,
          describable_id: @description.describable_id,
          kind: @description.kind, locale: @description.locale, rank: :preferred)
        .where.not(id: @description.id)
        .update_all(rank: 0)
      @description.update!(rank: :preferred)
    end

    respond_with_list(@description.describable, notice: "Preferred description updated.")
  end

  private

  def domain_auth_parent
    if action_name.in?(%w[update destroy set_preferred])
      find_description.describable
    else
      Admin::DomainRouting.parent_from_params(params, domain: current_domain)
    end
  end

  def set_parent
    @parent = Admin::DomainRouting.parent_from_params(params, domain: current_domain)
  end

  def set_description
    @description = find_description
  end

  # domain_auth_parent (require_domain_write!) and set_description both need the
  # record, and the former runs first as a before_action — memoize so a single
  # mutating request issues one SELECT, not two.
  def find_description
    @description ||= Description.find(params[:id])
  end

  # rank is deliberately absent (C4): only set_preferred changes it, transactionally.
  # kind and locale are absent too (C5) and are forced in create.
  #
  # Source Name only means anything for :other, and the form hides that input rather
  # than removing it -- so switching an existing :other row to Wikipedia still submits
  # the old name, which `validates :source_name, absence: true` then rejects with a 422
  # pointing at a field the admin cannot see. An explicitly submitted non-other source
  # drops it. Doing this server-side rather than in the Stimulus toggle keeps the rule
  # true without JS, and leaves the hidden input's value intact so toggling back to
  # "Other" restores what was typed.
  #
  # Guarded on `source` being present: a partial update that omits it must not clear a
  # source_name the record legitimately holds.
  def description_params
    permitted = params.require(:description).permit(:content, :source, :source_name, :source_url, :license)
    permitted[:source_name] = nil if permitted[:source].present? && permitted[:source] != "other"
    permitted
  end

  def respond_with_list(describable, notice:)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
          turbo_stream.replace("descriptions_list", template: "admin/descriptions/index",
            locals: {parent: describable, descriptions: describable.descriptions.reload.order(rank: :desc, source: :asc)})
        ]
      end
      format.html { redirect_to redirect_path_for(describable), notice: notice }
    end
  end

  def respond_with_error(description)
    message = description.errors.full_messages.join(", ")
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace("flash", partial: "admin/shared/flash",
          locals: {flash: {error: message}}), status: :unprocessable_entity
      end
      format.html { redirect_to redirect_path_for(description.describable), alert: message }
    end
  end

  def redirect_path_for(describable)
    Admin::DomainRouting.path_for(describable) || admin_root_path
  end
end
