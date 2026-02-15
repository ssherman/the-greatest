# frozen_string_literal: true

module Services
  module Games
    class AmazonProductService
      def self.call(game:)
        new(game).call
      end

      def initialize(game)
        @game = game
        @errors = []
      end

      def call
        return failure("Game title required") if @game.title.blank?

        # Step 1: Search Amazon for products
        search_results = search_amazon_products
        Rails.logger.info "Amazon search returned #{search_results&.count || 0} products for game: #{@game.title}"
        return failure("Amazon API search failed: #{@errors.join(", ")}") unless search_results

        if search_results.empty?
          Rails.logger.info "No Amazon products found for game: #{@game.title}"
          return success("No products found")
        end

        # Step 2: Use AI to validate matches
        validated_results = validate_matches_with_ai(search_results)
        Rails.logger.info "AI validation returned: #{validated_results&.count || 0} matches"
        return failure("AI validation failed: #{@errors.join(", ")}") unless validated_results

        if validated_results.empty?
          Rails.logger.info "No matching products found after AI validation"
          return success("No matching products found")
        end

        # Step 3: Create external links for all validated matches (NO image download)
        external_links = create_external_links(validated_results, search_results)

        success("Amazon enrichment completed: #{validated_results.count} products, #{external_links.count} links created")
      rescue => e
        Rails.logger.error "Amazon service error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        failure("Amazon service error: #{e.message}")
      end

      private

      AMAZON_RESOURCES = [
        "ItemInfo.Title",
        "ItemInfo.ByLineInfo",
        "ItemInfo.Classifications",
        "ItemInfo.ContentInfo",
        "Images.Primary.Small",
        "Images.Primary.Medium",
        "Images.Primary.Large",
        "BrowseNodeInfo.WebsiteSalesRank",
        "Offers.Listings.Price",
        "Offers.Summaries.LowestPrice"
      ].freeze

      def search_amazon_products
        client = amazon_client
        return nil unless client

        Rails.logger.info "Searching Amazon for game: '#{@game.title}'"

        # Search all categories to find guides, soundtracks, collectibles, etc.
        response = client.search_items(
          keywords: @game.title,
          search_index: "All",
          resources: AMAZON_RESOURCES
        )

        result = response.to_h
        items = result.dig("SearchResult", "Items") || []

        Rails.logger.info "Amazon returned #{items.count} results"
        items
      rescue => e
        @errors << "Amazon API error: #{e.message}"
        Rails.logger.error "Amazon API error: #{e.message}"
        nil
      end

      def amazon_client
        access_key = ENV["AMAZON_PRODUCT_API_ACCESS_KEY"]
        secret_key = ENV["AMAZON_PRODUCT_API_SECRET_KEY"]
        partner_tag = ENV["AMAZON_PRODUCT_API_PARTNER_KEY"]

        if access_key.blank? || secret_key.blank? || partner_tag.blank?
          @errors << "Amazon API credentials not configured"
          return nil
        end

        Vacuum.new(
          marketplace: "US",
          access_key: access_key,
          secret_key: secret_key,
          partner_tag: partner_tag
        )
      end

      def validate_matches_with_ai(search_results)
        return [] if search_results.empty?

        ai_task = ::Services::Ai::Tasks::Games::AmazonGameMatchTask.new(
          parent: @game,
          search_results: search_results
        )

        result = ai_task.call

        Rails.logger.info "AI Task Result: success=#{result.success?}, data=#{result.data.inspect}"

        if result.success?
          matching_results = result.data[:matching_results] || []
          Rails.logger.info "Found #{matching_results.count} matching results from AI"
          matching_results
        else
          @errors << result.error
          Rails.logger.error "AI task failed: #{result.error}"
          nil
        end
      end

      def create_external_links(validated_results, search_results)
        links = []
        Rails.logger.info "Creating external links for #{validated_results.count} validated results"

        validated_results.each do |match|
          product = search_results.find { |item| item["ASIN"] == match[:asin] }
          next unless product

          # Extract price information
          price_cents = extract_price_cents(product)

          # Use ASIN as unique identifier to prevent duplicates
          link = @game.external_links.find_or_create_by!(
            source: :amazon,
            url: product["DetailPageURL"]
          ) do |new_link|
            new_link.name = product.dig("ItemInfo", "Title", "DisplayValue") || "Amazon Product"
            new_link.link_category = :product_link
            new_link.price_cents = price_cents
            new_link.metadata = {
              amazon: product,
              product_type: match[:product_type],
              platform: match[:platform]
            }
            new_link.public = true
          end

          # Update price and metadata even for existing links
          if link.persisted? && !link.changed?
            link.update!(
              price_cents: price_cents,
              metadata: {
                amazon: product,
                product_type: match[:product_type],
                platform: match[:platform]
              }
            )
          end

          links << link
          Rails.logger.info "#{link.previously_new_record? ? "Created" : "Updated"} external link: #{link.name}"
        end

        links
      rescue => e
        @errors << "Failed to create external links: #{e.message}"
        Rails.logger.error "External link creation error: #{e.message}"
        []
      end

      def extract_price_cents(product)
        # Try to get lowest new price first
        new_price = product.dig("Offers", "Summaries")&.find { |s| s.dig("Condition", "Value") == "New" }
        price_amount = new_price&.dig("LowestPrice", "Amount")

        # Fallback to any lowest price
        if price_amount.nil?
          first_price = product.dig("Offers", "Summaries")&.first
          price_amount = first_price&.dig("LowestPrice", "Amount")
        end

        price_amount ? (price_amount * 100).to_i : nil
      end

      def success(message)
        {success: true, data: message}
      end

      def failure(error)
        {success: false, error: error, errors: @errors}
      end
    end
  end
end
