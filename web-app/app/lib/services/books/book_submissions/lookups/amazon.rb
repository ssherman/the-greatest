# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      module Lookups
        # Amazon, by ASIN or by ISBN. Only the product's title, authors and
        # year are read; its other identifiers are never returned.
        module Amazon
          module_function

          RESOURCES = ::Services::Books::AmazonProductService::AMAZON_RESOURCES

          def by_asin(asin)
            ::Services::Amazon::Client.get_items(item_ids: [asin], resources: RESOURCES)
              .filter_map { |product| answer(product) }.first
          end

          # A keyword search is fuzzy, so only a product that carries the ISBN
          # itself counts.
          def by_isbn(isbn13)
            ::Services::Amazon::Client.search_items(keywords: isbn13, search_index: "Books", resources: RESOURCES)
              .select { |product| carries?(product, isbn13) }
              .filter_map { |product| answer(product) }.first
          end

          def answer(product)
            title, subtitle = ::Services::Books::AmazonBookCheck.split_title(product.dig("itemInfo", "title", "displayValue"))
            answer = Answer.build(
              title: title, subtitle: subtitle,
              author_names: ::Services::Books::AmazonBookCheck.author_names(product),
              year: product.dig("itemInfo", "contentInfo", "publicationDate", "displayValue")
            )
            answer if answer.usable?
          end

          def carries?(product, isbn)
            ids = product.dig("itemInfo", "externalIds") || {}
            %w[isbns eans].flat_map { |kind| Array(ids.dig(kind, "displayValues")) }
              .any? { |value| value.to_s.delete("-") == isbn }
          end
        end
      end
    end
  end
end
