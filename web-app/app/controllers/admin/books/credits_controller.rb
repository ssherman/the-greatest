class Admin::Books::CreditsController < Admin::Books::BaseController
  before_action :set_credit, only: [:update, :destroy]

  def create
    @creditable = Admin::DomainRouting.parent_from_params(params, domain: :books)
    authorize_creditable
    @credit = @creditable.credits.build(credit_params)

    if @credit.save
      respond_to do |format|
        format.turbo_stream { render_credits("Credit added.") }
        format.html { redirect_to creditable_path(@creditable), notice: "Credit added." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_credit_error }
        format.html { redirect_to creditable_path(@creditable), alert: @credit.errors.full_messages.join(", ") }
      end
    end
  end

  def update
    @creditable = @credit.creditable
    authorize_creditable

    if @credit.update(credit_params)
      respond_to do |format|
        format.turbo_stream { render_credits("Credit updated.") }
        format.html { redirect_to creditable_path(@creditable), notice: "Credit updated." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_credit_error }
        format.html { redirect_to creditable_path(@creditable), alert: @credit.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @creditable = @credit.creditable
    authorize_creditable
    @credit.destroy!

    respond_to do |format|
      format.turbo_stream { render_credits("Credit removed.") }
      format.html { redirect_to creditable_path(@creditable), notice: "Credit removed." }
    end
  end

  private

  def set_credit
    @credit = ::Books::Credit.find(params[:id])
  end

  def credit_params
    params.require(:books_credit).permit(:author_id, :role, :position)
  end

  def authorize_creditable
    policy_class = @creditable.is_a?(::Books::Edition) ? ::Books::EditionPolicy : ::Books::BookPolicy
    authorize @creditable, :update?, policy_class: policy_class
  end

  def creditable_path(creditable)
    creditable.is_a?(::Books::Edition) ? admin_books_edition_path(creditable) : admin_books_book_path(creditable)
  end

  def render_credits(notice)
    render turbo_stream: [
      turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
      turbo_stream.replace("credits_list", partial: "admin/books/credits/credits_list", locals: {creditable: @creditable})
    ]
  end

  def render_credit_error
    render turbo_stream: turbo_stream.replace(
      "flash", partial: "admin/shared/flash", locals: {flash: {error: @credit.errors.full_messages.join(", ")}}
    ), status: :unprocessable_entity
  end
end
