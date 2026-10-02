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
    # title equals another book's by the same author, or a book whose
    # authors were only made equal by an author rename -- are raised as
    # bulk_verify pairs; nothing is merged.
    #
    # `report` (apply: false) is read-only. `apply` saves through the model
    # callbacks, one row at a time, so slugs, reindex requests and the
    # normalizers behave exactly as on any other save. A row the normalizer
    # cannot save (its trimmed value is blank) is recorded in `errors` and
    # skipped rather than aborting the run.
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
        @flagged_pairs = Set.new
        @errors = []
      end

      def call
        books = scan(::Books::Book, :title)
        authors = scan(::Books::Author, :name)

        if @apply
          renamed_author_ids = apply_authors(authors[:ids] | ids_with_list_changes(::Books::Author, :alternate_names))
          check_books_of_renamed_authors(renamed_author_ids)
          apply_books(books[:ids] | ids_with_list_changes(::Books::Book, :alternate_titles))
        end

        Result.new(
          success?: @errors.empty?,
          data: {books: books.except(:ids), authors: authors.except(:ids), applied: @apply, pairs_flagged: @flagged_pairs.size},
          errors: @errors
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
      # normalizer: then the change is "whitespace only". QuoteNormalizer
      # runs on both sides of the comparison, so a quote/acute-accent fold
      # with no further NFKC delta also counts as whitespace only.
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

      # Returns the ids of the authors actually renamed (their `name` column
      # changed -- not a row visited only for a stale alternate_names entry).
      # That set is what check_books_of_renamed_authors needs: folding two
      # author names together is what can make two already-identical book
      # titles collide.
      def apply_authors(ids)
        renamed_ids = []
        ids.each_slice(BATCH_SIZE) do |slice|
          ::Books::Author.where(id: slice).order(:id).each do |author|
            before = author.name
            after = normalize(before)
            stale_alternates = Array(author.alternate_names)
            author.alternate_names = normalize_list(stale_alternates)
            changed_alternates = author.alternate_names - stale_alternates
            next unless save_row!(author)

            renamed_ids << author.id if before != after
            # Only values this run changed are checked (F3): the renamed name,
            # and any alternate name that only now equals another author's
            # name -- the finder counts alternate names as creator agreement.
            candidates = (before == after) ? [] : [after]
            candidates += changed_alternates
            collision = first_collision(candidates) { |value| author_collision(author, value) }
            flag("Books::Author", author, collision, before: before) if collision
          end
        end
        renamed_ids
      end

      def apply_books(ids)
        ids.each_slice(BATCH_SIZE) do |slice|
          ::Books::Book.where(id: slice).includes(:authors).order(:id).each do |book|
            before = book.title
            after = normalize(before)
            stale_alternates = Array(book.alternate_titles)
            book.alternate_titles = normalize_list(stale_alternates)
            changed_alternates = book.alternate_titles - stale_alternates
            next unless save_row!(book)

            # Same rule as the authors: the retitled title, plus any alternate
            # title that only now equals another same-author book's title --
            # the finder counts alternate titles as title agreement.
            candidates = (before == after) ? [] : [after]
            candidates += changed_alternates
            collision = first_collision(candidates) { |value| book_collision(book, value) }
            flag("Books::Book", book, collision, before: before) if collision
          end
        end
      end

      def first_collision(values)
        values.each do |value|
          collision = yield(value)
          return collision if collision
        end
        nil
      end

      # No ORDER BY/LIMIT on the filtered query -- see exact_scope in
      # DataImporters::Books::Book::Finder for why that shape defeats
      # index_books_authors_on_lower_name.
      def author_collision(author, name)
        ids = ::Books::Author.where("LOWER(name) = ?", name.downcase).where.not(id: author.id).pluck(:id)
        ::Books::Author.find(ids.min) if ids.any?
      end

      # Every book of a renamed author, checked for a title collision WITHOUT
      # being saved -- a no-op save would still fire after_commit and queue an
      # index request the book does not need. `renamed_author_ids` is already
      # scoped (by apply_authors) to authors whose name actually changed. A
      # book that also independently needed its own title normalized gets
      # checked again by apply_books below; harmless, since pairs_flagged
      # counts distinct pairs (F2), not flag calls.
      def check_books_of_renamed_authors(renamed_author_ids)
        return if renamed_author_ids.empty?

        ::Books::Book.joins(:book_authors)
          .where(books_book_authors: {author_id: renamed_author_ids})
          .distinct.includes(:authors)
          .find_each(batch_size: BATCH_SIZE) do |book|
          collision = book_collision(book, normalize(book.title))
          flag("Books::Book", book, collision, before: book.title) if collision
        end
      end

      # No ORDER BY/LIMIT on the filtered query -- see exact_scope in
      # DataImporters::Books::Book::Finder for why that shape defeats
      # index_books_books_on_lower_title.
      def book_collision(book, title)
        author_names = book.authors.map { |author| normalize(author.name).downcase }
        return nil if author_names.empty?

        ids = ::Books::Book.joins(book_authors: :author)
          .where("LOWER(books_books.title) = ?", title.downcase)
          .where("LOWER(books_authors.name) IN (?)", author_names)
          .where.not(id: book.id)
          .distinct.pluck(:id)
        ::Books::Book.find(ids.min) if ids.any?
      end

      def normalize_list(values)
        Array(values).map { |value| normalize(value.to_s) }.compact_blank.uniq
      end

      # A row the normalizer trims down to blank (an all-whitespace title or
      # name) fails presence validation; that row is reported in `errors` and
      # left as-is rather than aborting every other row's normalization.
      def save_row!(record)
        record.save!
        true
      rescue ActiveRecord::RecordInvalid => e
        @errors << "#{record.class.name}##{record.id}: #{e.message}"
        false
      end

      def flag(item_type, record, collision, before:)
        result = ::Services::DuplicateCandidates::Flag.call(
          item_type: item_type,
          ids: [record.id, collision.id],
          source: :bulk_verify,
          evidence: {reason: COLLISION_REASON, normalized_from: before}
        )
        @flagged_pairs << [item_type, result.data.item_a_id, result.data.item_b_id] if result.success? && result.data
      end
    end
  end
end
