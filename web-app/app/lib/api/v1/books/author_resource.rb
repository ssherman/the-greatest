# frozen_string_literal: true

module Api
  module V1
    module Books
      # The author as the API presents it. Compact by default (the index), with a
      # :full trait for show. Key order here IS the order in config/api/v1/openapi.yaml.
      #
      # Not AuthorSummaryResource: that is the {id, slug, name} embedded in a
      # book. This is the author as a resource of its own.
      #
      # Every model reference is root-anchored: inside Api::V1::Books a bare
      # `Books::Author` resolves to Api::V1::Books::Author and raises NameError.
      #
      # `params[:rank]` lets the index pass the rank it already has from the
      # RankedItem row instead of triggering a query per author; show omits it
      # and the resource reads the primary author ranking itself.
      #
      # Show does not embed books (spec D13): an unbounded array is the wrong
      # shape; /api/v1/authors/{slug}/books is the follow-up.
      class AuthorResource
        include Alba::Resource

        attributes :id, :slug, :name, :sort_name, :birth_year, :death_year

        attribute :rank do |author|
          params.key?(:rank) ? params[:rank] : author.primary_ranked_item&.rank
        end

        attribute :image_url do |author|
          file = author.primary_image&.file
          file&.attached? ? Rails.application.routes.url_helpers.rails_public_blob_url(file) : nil
        end

        attribute :url do |author|
          "#{::Api::Host.base_url}/author/#{author.slug}"
        end

        attribute :api_url do |author|
          "#{::Api::Host.base_url}/api/v1/authors/#{author.slug}"
        end

        trait :full do
          attributes :alternate_names, :kind

          # The descriptions subsystem, not the legacy books_authors.description
          # column (which the descriptions spec's step D7 drops).
          attribute :description do |author|
            author.primary_description(kind: :summary)&.content
          end
        end
      end
    end
  end
end
