# frozen_string_literal: true

module Categories
  # Finds the active category of the same type that already uses a category's
  # name, as its own name or as an alias. Only checked for a new category or a
  # changed name: a record is never blocked over a twin it already had, and a
  # case-only rename of a persisted record ("fantasy" -> "Fantasy") is not a
  # conflict with itself.
  class NameGuard
    def self.conflict(category)
      name = category.name.to_s.strip
      return nil if name.blank?
      return nil if category.persisted? && !category.name_changed?
      return nil if category.persisted? && category.name_was.to_s.strip.casecmp?(name)

      ::Category.active
        .where(type: category.type)
        .where.not(id: category.id)
        .where("LOWER(categories.name) = LOWER(:name) OR EXISTS (SELECT 1 FROM unnest(categories.alternative_names) AS alias WHERE LOWER(alias) = LOWER(:name))", name: name)
        .order(:id)
        .first
    end
  end
end
