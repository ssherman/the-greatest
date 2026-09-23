# frozen_string_literal: true

module Services
  module Books
    # Applies the save-time normalization (QuoteNormalizer, then
    # NameNormalizer: NFKC and Unicode-space folding) to every stored book
    # title and author name it would change, in place, and reports what
    # changed. The finder's exact source compares a normalized query with
    # the stored value, so a row written before the normalizer existed is
    # invisible to it until saved once. Collisions that fall out -- an
    # author whose folded name equals another author's, a book whose folded
    # title equals another book's by the same author -- are raised as
    # bulk_verify pairs; nothing is merged.
    #
    # `report` (apply: false) is read-only. `apply` saves through the model
    # callbacks, one row at a time, so slugs, reindex requests and the
    # normalizers behave exactly as on any other save.
    class NormalizeStoredNames
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      SAMPLE_LIMIT = 25
      BATCH_SIZE = 2000

      COLLISION_REASON = "same value after whitespace/NFKC normalization"

      def self.call(apply: false)
        new(apply: apply).call
      end

      def initialize(apply: false)
        @apply = apply
        @pairs_flagged = 0
      end

      def call
        books = scan(::Books::Book, :title)
        authors = scan(::Books::Author, :name)

        if @apply
          apply_authors(authors[:ids] | ids_with_list_changes(::Books::Author, :alternate_names))
          apply_books(books[:ids] | ids_with_list_changes(::Books::Book, :alternate_titles))
        end

        Result.new(
          success?: true,
          data: {books: books.except(:ids), authors: authors.except(:ids), applied: @apply, pairs_flagged: @pairs_flagged},
          errors: []
        )
      end

      private

      # ---- report ---------------------------------------------------------

      def scan(model, column)
        counts = {scanned: 0, whitespace: 0, nfkc: 0, changed: 0, samples: [], ids: []}
        model.select(:id, column).find_each(batch_size: BATCH_SIZE) do |row|
          before = row.public_send(column).to_s
          after = normalize(before)
          counts[:scanned] += 1
          next if after == before

          counts[:changed] += 1
          counts[:ids] << row.id
          if nfkc_changed?(before)
            counts[:nfkc] += 1
          else
            counts[:whitespace] += 1
          end
          counts[:samples] << {id: row.id, before: before, after: after} if counts[:samples].size < SAMPLE_LIMIT
        end
        counts
      end

      def normalize(text)
        ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text))
      end

      # Whitespace folding alone would give the same answer as the full
      # normalizer: then the change is "whitespace only".
      def nfkc_changed?(text)
        quoted = ::Services::Text::QuoteNormalizer.call(text)
        whitespace_only = quoted.gsub(::Services::Text::NameNormalizer::SPACES, " ").squeeze(" ").strip
        normalize(text) != whitespace_only
      end

      # ---- apply ----------------------------------------------------------

      # A row whose primary column is already normalized can still hold an
      # unnormalized alternate_names/alternate_titles entry (written past the
      # callbacks, same as the primary column). apply must save that row too,
      # even though the report above counts only the primary column.
      def ids_with_list_changes(model, column)
        ids = []
        model.select(:id, column).find_each(batch_size: BATCH_SIZE) do |row|
          values = row.public_send(column)
          ids << row.id if normalize_list(values) != values
        end
        ids
      end

      def apply_authors(ids)
        ids.each_slice(BATCH_SIZE) do |slice|
          ::Books::Author.where(id: slice).order(:id).each do |author|
            before = author.name
            after = normalize(before)
            author.alternate_names = normalize_list(author.alternate_names)
            author.save! # the before_validation callback rewrites name
            collision = ::Books::Author.where("LOWER(name) = ?", after.downcase).where.not(id: author.id).order(:id).first
            flag("Books::Author", author, collision, before: before) if collision
          end
        end
      end

      def apply_books(ids)
        ids.each_slice(BATCH_SIZE) do |slice|
          ::Books::Book.where(id: slice).includes(:authors).order(:id).each do |book|
            before = book.title
            after = normalize(before)
            book.alternate_titles = normalize_list(book.alternate_titles)
            book.save! # the before_validation callback rewrites title
            author_names = book.authors.map { |author| normalize(author.name).downcase }
            next if author_names.empty?

            collision = ::Books::Book.joins(book_authors: :author)
              .where("LOWER(books_books.title) = ?", after.downcase)
              .where("LOWER(books_authors.name) IN (?)", author_names)
              .where.not(id: book.id).distinct.order(:id).first
            flag("Books::Book", book, collision, before: before) if collision
          end
        end
      end

      def normalize_list(values)
        Array(values).map { |value| normalize(value.to_s) }.compact_blank.uniq
      end

      def flag(item_type, record, collision, before:)
        result = ::Services::DuplicateCandidates::Flag.call(
          item_type: item_type,
          ids: [record.id, collision.id],
          source: :bulk_verify,
          evidence: {reason: COLLISION_REASON, normalized_from: before}
        )
        @pairs_flagged += 1 if result.success? && result.data
      end
    end
  end
end
