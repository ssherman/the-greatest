# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Live books locations by comparison key, built at apply time (after the
    # renames and merges have landed) so set_parent resolves parent names
    # against the vocabulary as it now is. Names beat alternative names; the
    # most-linked category wins a shared key.
    class LocationLookup
      def initialize
        @by_key = {}
        categories = ::Books::Category.active.where(category_type: :location).order(item_count: :desc, id: :asc).to_a
        categories.each { |category| index(category.name, category.id) }
        categories.each do |category|
          category.alternative_names.each { |alt| index(alt, category.id) }
        end
      end

      def register(category)
        index(category.name, category.id)
      end

      def find(name)
        key = NameNormalizer.twin_key(name)
        key && @by_key[key]
      end

      private

      # A name with no letters or digits has no key; it is never indexed.
      def index(name, id)
        key = NameNormalizer.twin_key(name)
        @by_key[key] ||= id if key
      end
    end
  end
end
