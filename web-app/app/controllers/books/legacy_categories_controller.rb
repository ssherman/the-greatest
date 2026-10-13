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
  # coincidentally equal legacy id. A merged category resolves to its target;
  # a category deleted without a merge still 404s, as on legacy.
  def find_category!
    category = Books::CategorySlugResolver.call(params[:id]) || find_by_legacy_id
    category&.canonical || raise(ActiveRecord::RecordNotFound)
  end

  # Category ids were not preserved by the migration, so a numeric id resolves
  # through LegacyIdMap. find_by(id:), never .find: Category uses friendly_id
  # with :finders, which resolves slugs before primary keys.
  def find_by_legacy_id
    return nil unless /\A\d+\z/.match?(params[:id])

    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: params[:id])
    new_id && Books::Category.find_by(id: new_id)
  end
end
