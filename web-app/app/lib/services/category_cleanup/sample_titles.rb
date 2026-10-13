# frozen_string_literal: true

module Services
  module CategoryCleanup
    # A few books carrying a category, for the model's context. Oldest ids
    # first: those are the long-standing legacy records, which skew towards
    # well-known books the model can place.
    class SampleTitles
      def self.for(category)
        limit = Rails.configuration.x.categories_cleanup.sample_titles
        ::Books::Book
          .joins(:category_items).where(category_items: {category_id: category.id}).merge(::CategoryItem.direct)
          .includes(:authors).order(:id).limit(limit)
          .map do |book|
            names = book.authors.map(&:name)
            names.any? ? "#{book.title} by #{names.join(", ")}" : book.title
          end
      end
    end
  end
end
