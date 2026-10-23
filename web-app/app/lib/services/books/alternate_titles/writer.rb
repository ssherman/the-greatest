# frozen_string_literal: true

module Services
  module Books
    module AlternateTitles
      # The one way to change a book's alternate titles. Rows in
      # books_alternate_titles are the truth; the books_books.alternate_titles
      # array is a copy of the book's kept and review rows (ordered by id) that
      # every method here re-assigns. Only `decide` saves the book; the other
      # methods leave that to the caller so they can ride its own save.
      #
      # A removed title is never added back by legacy, merge or ai_enrichment.
      # Only admin and correction may reinstate one.
      class Writer
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        REMOVED_BY = {admin: "removed by admin", correction: "removed by correction"}.freeze
        KEPT_BY_ADMIN = "kept by admin"
        REINSTATING_SOURCES = %i[admin correction].freeze
        VERDICT_COLUMNS = %w[status reason verdict category confidence ai_chat_id decided_by
          decided_by_user_id decided_at judged_at undo_checked_at].freeze

        class << self
          def add(book:, titles:, source:)
            Backfill.call(book)
            data = {added: [], reinstated: [], skipped_removed: []}
            ::Books::AlternateTitle.transaction { write_titles(book, titles, source, data) }
            assign_copy(book)
            success(data)
          end

          def replace(book:, titles:, source:, user: nil)
            unless REINSTATING_SOURCES.include?(source.to_sym)
              raise ArgumentError, "replace needs source :admin or :correction, got #{source.inspect}"
            end
            source = source.to_sym

            Backfill.call(book)
            data = {added: [], reinstated: [], removed: []}
            ::Books::AlternateTitle.transaction do
              incoming = unique_titles(titles).reject { |normalized, _| normalized == main_normalized(book) }
              now = Time.current
              book.alternate_title_records.listed.each do |row|
                next if incoming.key?(row.normalized_title)
                row.update!(status: :removed, reason: REMOVED_BY.fetch(source), decided_by: source,
                  decided_by_user_id: user&.id, decided_at: now)
                data[:removed] << row.title
              end
              write_titles(book, incoming.values, source, data, user: user)
              book.alternate_title_records.where(normalized_title: incoming.keys).each do |row|
                spelling = incoming[row.normalized_title]
                row.update!(title: spelling) if row.title != spelling
              end
            end
            assign_copy(book)
            success(data)
          end

          def decide(row:, status:, user: nil)
            status = status.to_sym
            raise ArgumentError, "status must be :kept or :removed" unless %i[kept removed].include?(status)

            attrs = {status: status, decided_by: :admin, decided_by_user_id: user&.id, decided_at: Time.current}
            default_reason = (status == :removed) ? REMOVED_BY[:admin] : KEPT_BY_ADMIN
            generated = REMOVED_BY.values + [KEPT_BY_ADMIN]
            attrs[:reason] = default_reason if row.reason.blank? || generated.include?(row.reason)
            book = row.book
            ::Books::AlternateTitle.transaction do
              row.update!(attrs)
              assign_copy(book)
              book.save!
            end
            success({row: row})
          end

          # Moves every row of source_book to target_book (merger). Returns the
          # titles that became listed on the target.
          def move(source_book:, target_book:)
            Backfill.call(source_book)
            Backfill.call(target_book)
            before = listed_titles(target_book)
            ::Books::AlternateTitle.transaction do
              target_rows = target_book.alternate_title_records.index_by(&:normalized_title)
              target_main = main_normalized(target_book)
              source_book.alternate_title_records.order(:id).each do |row|
                if (existing = target_rows[row.normalized_title])
                  carry_removal(row, existing)
                  row.destroy!
                elsif row.normalized_title == target_main
                  row.destroy!
                else
                  row.update_columns(book_id: target_book.id)
                  target_rows[row.normalized_title] = row
                end
              end
              write_titles(target_book, [source_book.title], :merge, {added: [], reinstated: [], skipped_removed: []})
            end
            assign_copy(target_book)
            target_book.alternate_titles - before
          end

          def listed_titles(book)
            book.alternate_title_records.listed.pluck(:title)
          end

          private

          def success(data) = Result.new(success?: true, data: data, errors: [])

          def normalize(title) = ::Services::Books::Verification::Check.normalize(title)

          def main_normalized(book) = normalize(book.title)

          def assign_copy(book)
            book.alternate_titles = listed_titles(book)
          end

          # normalized form => first spelling
          def unique_titles(titles)
            Array(titles).each_with_object({}) do |title, seen|
              normalized = normalize(title)
              seen[normalized] ||= title.to_s.strip if normalized.present?
            end
          end

          def write_titles(book, titles, source, data, user: nil)
            source = source.to_sym
            main = main_normalized(book)
            existing = book.alternate_title_records.index_by(&:normalized_title)
            now = Time.current
            unique_titles(titles).each do |normalized, title|
              next if normalized == main

              row = existing[normalized]
              if row.nil?
                existing[normalized] = book.alternate_title_records.create!(title: title, source: source, status: :kept)
                data[:added] << title
              elsif row.removed?
                if REINSTATING_SOURCES.include?(source)
                  row.update!(status: :kept, source: source, decided_by: source,
                    decided_by_user_id: user&.id, decided_at: now)
                  data[:reinstated] << row.title
                else
                  data[:skipped_removed] << title
                end
              end
            end
          end

          # Removed wins: when either side of a duplicate is removed the target's
          # row ends up removed, with the source's verdict if the source was the
          # removed one.
          def carry_removal(source_row, target_row)
            return unless source_row.removed? && !target_row.removed?

            target_row.update_columns(source_row.attributes.slice(*VERDICT_COLUMNS).merge("updated_at" => Time.current))
          end
        end
      end
    end
  end
end
