class Admin::Books::CategoriesController < Admin::CategoriesBaseController
  include Admin::DomainScopedAuth

  # Not `before_action :set_category, only: [:merge]`: redeclaring a callback
  # replaces the base controller's, which would drop show/edit/update/destroy.
  before_action :load_and_authorize_merge_category, only: [:merge]

  # Merging deletes the source, so it needs the destroy permission.
  def merge
    target = ::Books::Category.active.find_by(id: params[:target_category_id])
    return redirect_to(admin_books_category_path(@category), alert: "Pick a category to merge into.") if target.nil?
    return redirect_to(admin_books_category_path(@category), alert: "Tick the box to confirm the merge.") unless params[:confirm_merge] == "1"

    ::Categories::Merger.new(category: @category, category_to_merge_with: target).merge
    redirect_to admin_books_category_path(target), notice: "Merged \"#{@category.name}\" into \"#{target.name}\"."
  rescue ::Categories::Refused => e
    redirect_to admin_books_category_path(@category), alert: e.message
  end

  # A location moved to a new parent changes the inherited links of every
  # book under it; the whole-catalog reconcile takes seconds in production,
  # so it runs in the background.
  def update
    parent_before = @category.parent_id
    if @category.update(category_params)
      ::Categories::ReconcileAncestorsJob.perform_async if @category.location? && @category.parent_id != parent_before
      redirect_to admin_books_category_path(@category), notice: "Category updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Books deletes through Categories::Deleter so the links go too and the
  # book-type categories are refused. Music and games keep the base behaviour.
  def destroy
    ::Categories::Deleter.new(category: @category, soft: true).delete
    redirect_to categories_path, notice: "Category deleted successfully."
  rescue ::Categories::Refused => e
    redirect_to admin_books_category_path(@category), alert: e.message
  end

  protected

  def model_class = ::Books::Category

  def param_key = :books_category

  def category_path(category) = admin_books_category_path(category)

  def categories_path = admin_books_categories_path

  def categories_search_path = search_admin_books_categories_path

  def new_category_path = new_admin_books_category_path

  def edit_category_path(category) = edit_admin_books_category_path(category)

  def domain_label = "Books"

  def subtitle = "Manage book genres, subjects, locations, and themes"

  def load_show_stats
    @stats = {
      "Books" => @category.books.count,
      "Authors" => @category.authors.count
    }
  end

  private

  def load_and_authorize_merge_category
    set_category
    authorize @category, :destroy?
  end
end
