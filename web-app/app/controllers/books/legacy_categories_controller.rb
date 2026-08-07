class Books::LegacyCategoriesController < ApplicationController
  # Legacy /genres/:id rendered BookListQuery.call(categories: [category]) --
  # exactly what /the-greatest/:slug/books renders -- so this redirects to
  # existing content rather than duplicating it.
  def show
    redirect_to Books::FilterPath.call(categories: [find_category!]),
      status: :moved_permanently
  end

  private

  # Slug before id, matching legacy's Category.active.friendly.find AND because
  # 206 books categories have a purely numeric slug that must beat a
  # coincidentally equal legacy id. Scoped to .active so the 21,191 soft-deleted
  # categories 404 the way legacy does.
  def find_category!
    Books::Category.active.find_by(slug: params[:id]) || find_by_legacy_id!
  end

  # Category ids were not preserved by the migration, so a numeric id resolves
  # through LegacyIdMap. find_by!(id:), never .find: Category uses friendly_id
  # with :finders, which resolves slugs before primary keys.
  def find_by_legacy_id!
    raise ActiveRecord::RecordNotFound unless /\A\d+\z/.match?(params[:id])

    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: params[:id])
    raise ActiveRecord::RecordNotFound if new_id.nil?

    Books::Category.active.find_by!(id: new_id)
  end
end
