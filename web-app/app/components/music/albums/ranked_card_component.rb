module Music
  module Albums
    class RankedCardComponent < ViewComponent::Base
      include Music::DefaultHelper

      def initialize(ranked_item:, ranking_configuration: nil)
        @ranked_item = ranked_item
        @ranking_configuration = ranking_configuration
      end

      private

      attr_reader :ranked_item, :ranking_configuration

      def album
        @album ||= ranked_item.item
      end
    end
  end
end
