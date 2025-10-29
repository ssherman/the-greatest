module Music
  module Albums
    class CardComponent < ViewComponent::Base
      include Music::DefaultHelper

      def initialize(album: nil, ranked_item: nil, ranking_configuration: nil)
        if album.nil? && ranked_item.nil?
          raise ArgumentError, "Must provide either album: or ranked_item:"
        end

        @album = album
        @ranked_item = ranked_item
        @ranking_configuration = ranking_configuration
      end

      private

      attr_reader :album, :ranked_item, :ranking_configuration

      def show_rank?
        ranked_item.present?
      end

      def item_album
        @item_album ||= album || ranked_item.item
      end
    end
  end
end
