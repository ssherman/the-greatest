# frozen_string_literal: true

module Api
  module V1
    module Books
      # The book as the API presents it. Compact by default (the index), with a
      # :full trait for show. Key order here IS the order in config/api/v1/openapi.yaml.
      #
      # Every model reference is root-anchored: inside Api::V1::Books a bare
      # `Books::Book` resolves to Api::V1::Books::Book and raises NameError.
      #
      # `params[:rank]` lets the index pass the rank it already has from the
      # RankedItem row instead of triggering a query per book; show omits it and
      # the resource reads the primary ranking itself.
      class BookResource
        include Alba::Resource

        attributes :id, :slug, :title, :subtitle, :first_published_year

        attribute :rank do |book|
          params.key?(:rank) ? params[:rank] : book.primary_ranked_item&.rank
        end

        # book_authors, not authors: the through association would not use the
        # preloaded rows, and book_authors carries the position order.
        attribute :authors do |book|
          book.book_authors.map { |book_author| AuthorSummaryResource.new(book_author.author).to_h }
        end

        attribute :cover_url do |book|
          file = book.primary_image&.file
          file&.attached? ? Rails.application.routes.url_helpers.rails_public_blob_url(file) : nil
        end

        attribute :url do |book|
          "#{::Api::Host.base_url}/book/#{book.slug}"
        end

        attribute :api_url do |book|
          "#{::Api::Host.base_url}/api/v1/books/#{book.slug}"
        end

        trait :full do
          attributes :sort_title, :alternate_titles, :book_kind, :book_length, :page_range, :word_count

          attribute :description do |book|
            book.primary_description(kind: :summary)&.content
          end

          attribute :original_language do |book|
            language = book.original_language
            language && {id: language.id, slug: language.slug, name: language.name}
          end

          # reject(&:deleted?) on the preloaded rows rather than the .active scope,
          # which would issue a fresh query per book.
          attribute :categories do |book|
            book.categories.reject(&:deleted?).map do |category|
              {id: category.id, slug: category.slug, name: category.name, category_type: category.category_type}
            end
          end

          attribute :countries do |book|
            book.countries.map { |country| {id: country.id, slug: country.slug, name: country.name} }
          end
        end
      end
    end
  end
end
