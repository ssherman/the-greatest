# frozen_string_literal: true

module Services
  module Music
    class AmazonProductService < ::Services::Amazon::BaseProductService
      def self.call(album:)
        new(album).call
      end

      private

      alias_method :album, :record

      def validation_errors
        return ["Album title required"] if album.title.blank?
        return ["Album must have at least one artist"] if album.artists.empty?
        []
      end

      def search_param_sets
        [{
          artist: album.artists.first.name,
          title: album.title,
          search_index: "Music"
        }]
      end

      def match_task_class
        ::Services::Ai::Tasks::Music::AmazonAlbumMatchTask
      end

      def persist_match(match, product)
        upsert_external_link(parent: album, product: product)
      end

      # Amazon is a fallback cover source for albums. attach_primary_image
      # already no-ops when the album has one, so no extra guard is needed here.
      def after_persist(validated_results, search_results)
        product = best_product(validated_results, search_results, require_image: true)
        return if product.nil?

        attach_primary_image(parent: album, image_url: image_url_for(product))
      end
    end
  end
end
