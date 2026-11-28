# frozen_string_literal: true

module Services
  module Books
    # Puts the ASIN and ISBNs of an Amazon edition on its book where the
    # enrichment skipped them only because Amazon credited the author "Last,
    # First" (AmazonBookCheck.same_book? compared the name as given until
    # 2026-11-27). It reads the product stored on the edition and asks Amazon
    # nothing.
    #
    # One call handles one chunk of editions in id order, after `after_id`:
    # only editions our enrichment wrote (the lowerCamelCase `itemInfo` blob;
    # the legacy PascalCase blobs never reach same_book?) whose author credits
    # hold a comma. The same rules as a live enrichment apply: same_book?, then
    # AmazonBookIdentifiers and BookIdentifierWriter, which writes nothing and
    # flags a duplicate pair when another book holds a value from a verified
    # source. Reruns write nothing new. A dry run writes and flags nothing.
    class AmazonBookIdentifiersRepair
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)
      CHUNK = 500
      COUNTS = %i[checked same_book editions_written identifiers_written editions_flagged].freeze

      def self.call(after_id: 0, limit: CHUNK, dry_run: true)
        new(after_id: after_id, limit: limit, dry_run: dry_run).call
      end

      def initialize(after_id:, limit:, dry_run:)
        @after_id = after_id.to_i
        @limit = limit
        @dry_run = dry_run
      end

      def call
        stats = COUNTS.index_with(0).merge(last_id: @after_id)
        editions = self.class.scope.where("books_editions.id > ?", @after_id).order(:id).limit(@limit)
          .includes(book: :authors).to_a
        editions.each do |edition|
          stats[:last_id] = edition.id
          repair(edition, stats)
        end
        Result.new(success?: true, data: stats.merge(done: editions.size < @limit), errors: [])
      end

      def self.scope
        ::Books::Edition
          .where(%(jsonb_path_exists(books_editions.metadata, '$.amazon.itemInfo.byLineInfo.contributors[*].name ? (@ like_regex ",")')))
      end

      private

      def repair(edition, stats)
        book = edition.book
        product = edition.metadata["amazon"]
        return if book.nil? || !product.is_a?(Hash)

        stats[:checked] += 1
        return unless AmazonBookCheck.same_book?(book, product)

        stats[:same_book] += 1
        result = AmazonBookIdentifiers.call(book: book, product: product, dry_run: @dry_run)
        if result.flagged_book_ids.any?
          stats[:editions_flagged] += 1
        elsif result.created.any?
          stats[:editions_written] += 1
          stats[:identifiers_written] += result.created.size
        end
      end
    end
  end
end
