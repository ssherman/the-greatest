# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # One book with exactly the fields update_book takes, plus the names of the
        # fields an admin cleared on purpose. Key order is the order in
        # config/api/v1/admin_openapi.yaml. Root-anchor every ::Books:: reference.
        class BookDetailResource
          include Alba::Resource

          attributes :id, :slug, :title, :subtitle, :sort_title, :first_published_year, :book_kind

          attribute :original_language do |book|
            language = book.original_language
            language && {id: language.id, name: language.name}
          end

          attribute :alternate_titles do |book|
            book.alternate_titles
          end

          attributes :provisional

          attribute :authors do |book|
            book.authors.map { |author| ::Api::V1::Books::AuthorSummaryResource.new(author).to_h }
          end

          attribute :cleared_fields do |book|
            book.cleared_fields.map(&:field_name).sort
          end
        end
      end
    end
  end
end
