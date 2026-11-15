# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # One author on a book, with the join row's own fields. Built from a
        # Books::BookAuthor whose author is loaded. Key order is the order of
        # AdminBookAuthor in config/api/v1/admin_openapi.yaml.
        class BookAuthorEntryResource
          include Alba::Resource

          attribute(:id) { |book_author| book_author.author.id }
          attribute(:slug) { |book_author| book_author.author.slug }
          attribute(:name) { |book_author| book_author.author.name }
          attributes :role, :position, :credited_as
        end
      end
    end
  end
end
