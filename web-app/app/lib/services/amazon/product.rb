# frozen_string_literal: true

module Services
  module Amazon
    # Reads derived values out of a Creators API product hash.
    #
    # The Creators API dropped PA-API's Offers.Summaries, which handed you a
    # pre-computed LowestPrice per condition. OffersV2 only returns the
    # individual listings, so the equivalent figure has to be derived here
    # rather than read off the response.
    module Product
      module_function

      # Cheapest new listing in whole cents, falling back to the cheapest
      # listing of any condition. Returns nil when the product carries no
      # priced offers.
      def lowest_price_cents(product)
        listings = product.dig("offersV2", "listings") || []
        return nil if listings.empty?

        new_amounts = amounts(listings.select { |listing| listing.dig("condition", "value") == "New" })
        amount = (new_amounts.presence || amounts(listings)).min
        return nil if amount.nil?

        (amount * 100).round
      end

      def amounts(listings)
        listings.filter_map { |listing| listing.dig("price", "money", "amount") }
      end
      private_class_method :amounts
    end
  end
end
