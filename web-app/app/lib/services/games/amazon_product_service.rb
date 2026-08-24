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
        "itemInfo.title",
        "itemInfo.byLineInfo",
        "itemInfo.classifications",
        "itemInfo.contentInfo",
        "itemInfo.productInfo",
        "images.primary.small",
        "images.primary.medium",
        "images.primary.large",
        "browseNodeInfo.websiteSalesRank",
        "offersV2.listings.condition",
        "offersV2.listings.price"
      ].freeze

      def search_amazon_products
        Rails.logger.info "Searching Amazon for game: '#{@game.title}'"

        # Search all categories to find guides, soundtracks, collectibles, etc.
        items = ::Services::Amazon::Client.search_items(
          keywords: @game.title,
          search_index: "All",
          resources: AMAZON_RESOURCES
        )

        Rails.logger.info "Amazon returned #{items.count} results"
        items
      rescue => e
        @errors << "Amazon API error: #{e.message}"
        Rails.logger.error "Amazon API error: #{e.message}"
        nil
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
          product = search_results.find { |item| item["asin"] == match[:asin] }
          next unless product

          # Extract price information
          price_cents = extract_price_cents(product)

          # Use the detail page URL as the unique identifier to prevent duplicates
          link = @game.external_links.find_or_create_by!(
            source: :amazon,
            url: product["detailPageURL"]
          ) do |new_link|
            new_link.name = product.dig("itemInfo", "title", "displayValue") || "Amazon Product"
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
        ::Services::Amazon::Product.lowest_price_cents(product)
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
