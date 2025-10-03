# frozen_string_literal: true

module Services
  module Music
    class AmazonProductService
      def self.call(album:)
        new(album).call
      end

      def initialize(album)
        @album = album
        @errors = []
      end

      def call
        return failure("Album title required") if @album.title.blank?
        return failure("Album must have at least one artist") if @album.artists.empty?

        # Step 1: Search Amazon for products
        search_results = search_amazon_products
        Rails.logger.info "Amazon search returned #{search_results&.count || 0} products"
        return failure("Amazon API search failed: #{@errors.join(", ")}") unless search_results

        # Step 2: Use AI to validate matches
        validated_results = validate_matches_with_ai(search_results)
        Rails.logger.info "AI validation returned: #{validated_results.inspect}"
        return failure("AI validation failed: #{@errors.join(", ")}") unless validated_results

        if validated_results.empty?
          Rails.logger.info "No matching products found after AI validation"
          return success("No matching products found")
        end

        # Step 3: Create external links for all validated matches
        external_links = create_external_links(validated_results, search_results)

        # Step 4: Download and set primary image from best ranked product
        set_primary_image_from_best_product(validated_results, search_results)

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

        # Get first artist name for search
        artist_name = @album.artists.first.name

        Rails.logger.info "Searching Amazon for: artist='#{artist_name}', title='#{@album.title}'"

        response = client.search_items(
          artist: artist_name,
          title: @album.title,
          search_index: "Music",
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

        ai_task = Services::Ai::Tasks::Music::AmazonAlbumMatchTask.new(
          parent: @album,
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

        # binding.break
        validated_results.each do |match|
          product = search_results.find { |item| item["ASIN"] == match[:asin] }
          next unless product

          # Extract price information
          price_cents = extract_price_cents(product)

          # Use ASIN as unique identifier to prevent duplicates
          product["ASIN"]
          link = @album.external_links.find_or_create_by!(
            source: :amazon,
            url: product["DetailPageURL"]
          ) do |new_link|
            new_link.name = product.dig("ItemInfo", "Title", "DisplayValue") || "Amazon Product"
            new_link.link_category = :product_link
            new_link.price_cents = price_cents
            new_link.metadata = {amazon: product}
            new_link.public = true
          end

          # Update price and metadata even for existing links (products may have price changes)
          if link.persisted? && !link.changed?
            link.update!(
              price_cents: price_cents,
              metadata: {amazon: product}
            )
          end

          links << link
          Rails.logger.info "#{link.previously_new_record? ? "Created" : "Updated"} external link: #{link.name} (#{link.url})"
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

      def set_primary_image_from_best_product(validated_results, search_results)
        return if validated_results.empty?

        # Skip if album already has a primary image
        if @album.images.where(primary: true).exists?
          Rails.logger.info "Album #{@album.title} already has a primary image, skipping Amazon image download"
          return
        end

        # Find products with images, sorted by sales rank (lower = better)
        products_with_images = validated_results.map do |match|
          product = search_results.find { |item| item["ASIN"] == match[:asin] }
          next unless product

          image_url = product.dig("Images", "Primary", "Large", "URL")
          sales_rank = product.dig("BrowseNodeInfo", "WebsiteSalesRank", "SalesRank")

          next unless image_url

          {
            product: product,
            image_url: image_url,
            sales_rank: sales_rank || Float::INFINITY,
            asin: match[:asin]
          }
        end.compact

        return if products_with_images.empty?

        # Sort by sales rank (lower number = better ranking)
        best_product = products_with_images.min_by { |p| p[:sales_rank] }

        Rails.logger.info "Downloading image from best product: ASIN #{best_product[:asin]}, sales rank #{best_product[:sales_rank]}"

        download_and_set_image(best_product[:image_url])
      rescue => e
        @errors << "Failed to set primary image: #{e.message}"
        Rails.logger.error "Image download error: #{e.message}"
      end

      def download_and_set_image(image_url)
        tempfile = Down.download(image_url)
        return unless tempfile

        # Create Image record, attach file, then save
        image = @album.images.build(primary: true)
        image.file.attach(
          io: tempfile,
          filename: tempfile.original_filename,
          content_type: tempfile.content_type
        )
        image.save!

        Rails.logger.info "Successfully set primary image for album #{@album.title}"
      rescue => e
        Rails.logger.error "Failed to download image from #{image_url}: #{e.message}"
        @errors << "Image download failed: #{e.message}"
      ensure
        tempfile&.close
        tempfile&.unlink
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
