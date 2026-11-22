# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # One row of a list. `book` is the linked book (preload
        # listable: [:authors, :countries]) or null; `text` is the title and
        # author the list carried for a row with no linked book. Key order is
        # the order of AdminListItem in config/api/v1/admin_openapi.yaml.
        class ListItemResource
          include Alba::Resource

          attributes :id, :position, :verified

          attribute :book do |item|
            book = item.listable
            if book.is_a?(::Books::Book)
              {
                id: book.id, title: book.title, authors: book.authors.map(&:name),
                first_published_year: book.first_published_year, countries: book.countries.map(&:name)
              }
            end
          end

          attribute :text do |item|
            metadata = item.metadata.is_a?(Hash) ? item.metadata : {}
            author = metadata["author"].presence || Array(metadata["authors"]).join(", ").presence
            title = metadata["title"].presence
            {title: title, author: author} if item.listable_id.nil? && (title || author)
          end
        end
      end
    end
  end
end
