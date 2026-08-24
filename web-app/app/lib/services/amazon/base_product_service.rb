# frozen_string_literal: true

module Services
  module Amazon
    # Template-method base for the per-domain Amazon enrichment services.
    #
    # The pipeline -- search Amazon, ask an AI task which results genuinely match,
    # then persist -- is identical across music, games and books. What differs is
    # what a match becomes: an ExternalLink on the record for music and games, a
    # Books::Edition for books. Subclasses fill in the hooks; the pipeline, the
    # link and image writers, and the result shape live here.
    #
    # The result is a Hash rather than the Result struct used elsewhere because
    # both existing jobs and 359 lines of existing tests read result[:success]
    # and result[:error].
    class BaseProductService
      # Default resources requested from the Creators API. Books overrides this
      # to add itemInfo.externalIds, which carries the ISBNs and EANs it needs.
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

      def initialize(record)
        @record = record
        @errors = []
      end

      def call
        first_error = validation_errors.first
        return failure(first_error) if first_error

        search_results = search_amazon_products
        return failure("Amazon API search failed: #{@errors.join(", ")}") unless search_results
        return success("No products found") if search_results.empty?

        validated_results = validate_matches_with_ai(search_results)
        return failure("AI validation failed: #{@errors.join(", ")}") unless validated_results
        return success("No matching products found") if validated_results.empty?

        persisted = persist_matches(validated_results, search_results)
        after_persist(validated_results, search_results)

        success("Amazon enrichment completed: #{validated_results.count} products, #{persisted.count} links created")
      rescue => e
        Rails.logger.error "Amazon service error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        failure("Amazon service error: #{e.message}")
      end

      private

      attr_reader :record

      # ---- hooks every subclass must implement ---------------------------

      # Array of human-readable strings. The first one aborts the run.
      def validation_errors
        raise NotImplementedError, "Subclasses must implement #validation_errors"
      end

      # One Hash of search parameters per Amazon call. Most domains need a single
      # call; books makes a second pass against the Audible browse node because
      # the plain search never surfaces audiobooks.
      def search_param_sets
        raise NotImplementedError, "Subclasses must implement #search_param_sets"
      end

      def match_task_class
        raise NotImplementedError, "Subclasses must implement #match_task_class"
      end

      # Returns the ExternalLink created or refreshed for this match, or nil to
      # skip it. Whatever is returned is counted in the success message.
      def persist_match(match, product)
        raise NotImplementedError, "Subclasses must implement #persist_match"
      end

      # ---- optional hook -------------------------------------------------

      # Runs once after every match is persisted. Default is a no-op; music uses
      # it for the album cover, books for the book-level cover and affiliate link.
      def after_persist(validated_results, search_results)
        nil
      end

      def amazon_resources
        self.class::AMAZON_RESOURCES
      end

      # ---- pipeline ------------------------------------------------------

      def search_amazon_products
        param_sets = search_param_sets

        items = param_sets.flat_map do |params|
          ::Services::Amazon::Client.search_items(resources: amazon_resources, **params)
        end

        deduped = items.uniq { |item| item["asin"] }
        Rails.logger.info "Amazon returned #{deduped.count} unique results across #{param_sets.count} search(es)"
        deduped
      rescue => e
        @errors << "Amazon API error: #{e.message}"
        Rails.logger.error "Amazon API error: #{e.message}"
        nil
      end

      def validate_matches_with_ai(search_results)
        result = match_task_class.new(parent: record, search_results: search_results).call

        Rails.logger.info "AI task result: success=#{result.success?}"

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

      def persist_matches(validated_results, search_results)
        validated_results.filter_map do |match|
          product = product_for(match, search_results)

          if product.nil?
            Rails.logger.info "AI returned ASIN #{match[:asin].inspect}, which is not in the search results; skipping"
            next
          end

          begin
            persist_match(match, product)
          rescue => e
            # One unusable product must not discard every other match for this
            # record. Skip it, record it, and keep going -- a partial result with
            # a logged error beats silently dropping every other good match.
            @errors << "Failed to persist ASIN #{match[:asin]}: #{e.message}"
            Rails.logger.error "Persist error for ASIN #{match[:asin]}: #{e.message}"
            next
          end
        end
      end

      def product_for(match, search_results)
        search_results.find { |item| item["asin"] == match[:asin] }
      end

      # The matched product with the best (lowest) sales rank. Products carrying
      # no rank sort last rather than winning by virtue of a nil.
      #
      # require_image restricts the ranking to products that actually carry a
      # cover URL. Without it a rank winner with no image wins and then silently
      # produces no cover, even when a lower-ranked match has one.
      def best_product(validated_results, search_results, require_image: false)
        candidates = validated_results.filter_map { |match| product_for(match, search_results) }
        candidates = candidates.select { |product| image_url_for(product).present? } if require_image
        candidates.min_by { |product| product.dig("browseNodeInfo", "websiteSalesRank", "salesRank") || Float::INFINITY }
      end

      def image_url_for(product)
        product.dig("images", "primary", "large", "url")
      end

      def extract_price_cents(product)
        ::Services::Amazon::Product.lowest_price_cents(product)
      end

      # Creates the link when absent; refreshes price and metadata when present.
      # The detail page URL is the natural key -- it carries the partner tag, so
      # it is also the thing that earns affiliate revenue.
      def upsert_external_link(parent:, product:, metadata: {})
        link = parent.external_links.find_or_initialize_by(
          source: :amazon,
          url: product["detailPageURL"]
        )

        link.name = product.dig("itemInfo", "title", "displayValue").presence || "Amazon Product" if link.name.blank?
        link.link_category = :product_link
        link.public = true if link.new_record?
        link.price_cents = extract_price_cents(product)
        link.metadata = {amazon: product}.merge(metadata)
        link.save!

        Rails.logger.info "#{link.previously_new_record? ? "Created" : "Updated"} external link: #{link.name} (#{link.url})"
        link
      end

      # Attaches the Amazon cover as the parent's primary image. No-op when the
      # parent already has one -- Amazon is a fallback source, never an override
      # for curated art.
      def attach_primary_image(parent:, image_url:)
        return if image_url.blank?

        if parent.images.where(primary: true).exists?
          Rails.logger.info "#{parent.class.name} #{parent.id} already has a primary image; skipping Amazon download"
          return
        end

        tempfile = Down.download(image_url)
        return unless tempfile

        image = parent.images.build(primary: true)
        image.file.attach(
          io: tempfile,
          filename: tempfile.original_filename,
          content_type: tempfile.content_type
        )
        image.save!

        Rails.logger.info "Set primary image for #{parent.class.name} #{parent.id}"
        nil
      rescue => e
        @errors << "Image download failed: #{e.message}"
        Rails.logger.error "Failed to download image from #{image_url}: #{e.message}"
        nil
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
