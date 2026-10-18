# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # `categories:genres:split_check` (spec §5 step 4): asks, per book on a
      # split genre, which of the split's targets fit. Resumable by book.
      class SplitCheck
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(plan:, assignments:, batch_size: 10, force: false)
          new(plan, assignments, batch_size).call(force: force)
        end

        def self.calls_needed(plan:, assignments:, batch_size: 10)
          new(plan, assignments, batch_size).calls_needed
        end

        def initialize(plan, assignments, batch_size)
          @plan = plan
          @assignments = assignments
          @batch_size = batch_size
        end

        def calls_needed = work.sum { |_, _, books| (books.size / @batch_size.to_f).ceil }

        def call(force:)
          jobs = work
          ::Services::CategoryCleanup::CostGuard.check!(calls: calls_needed_for(jobs), force: force)
          checked = 0
          made = 0
          failed = 0
          jobs.each do |category, targets, book_ids|
            book_ids.each_slice(@batch_size) do |slice|
              books = ::Books::Book.where(id: slice).includes(:authors, :categories).index_by(&:id)
              # A link to a book that no longer exists has nothing to ask about.
              slice = slice.select { |book_id| books.key?(book_id) }
              next if slice.empty?

              entries = slice.each_with_index.map { |book_id, index| entry(books.fetch(book_id), (index + 1).to_s, category) }
              response = ::Services::Ai::Tasks::Books::GenreSplitCheckTask.new(genre: category.name, targets: targets, books: entries).call
              made += 1
              unless response.success?
                failed += 1
                Rails.logger.warn("[genre split_check] call failed: #{response.error}")
                next
              end

              rows = slice.each_with_index.map { |book_id, index| [book_id, category.id, response.data[:results].fetch((index + 1).to_s)] }
              @assignments.append(rows)
              checked += rows.size
            end
          end
          Result.new(success?: true, data: {checked: checked, calls: made, failed_calls: failed}, errors: [])
        end

        private

        def calls_needed_for(jobs) = jobs.sum { |_, _, books| (books.size / @batch_size.to_f).ceil }

        # [[category, target labels, [book ids not yet answered]], ...]
        def work
          @plan.decisions.sort.filter_map do |id, d|
            next unless d["action"] == "split"

            category = ::Books::Category.find_by(id: id)
            next if category.nil?

            book_ids = category.category_items.where(item_type: "Books::Book").order(:item_id).pluck(:item_id)
              .reject { |book_id| @assignments.answered?(id, book_id) }
            [category, Array(d["into"]).map { |entry| Validator.target_label(entry) }, book_ids]
          end
        end

        def entry(book, key, category)
          ::Services::Ai::Tasks::Books::GenreSplitCheckTask::Book.new(
            key: key, title: book.title, authors: book.authors.map(&:name), year: book.first_published_year,
            description: book.primary_description&.content,
            genres: book.categories.select { |c| !c.deleted && c.genre? && c.id != category.id }.map(&:name)
          )
        end
      end
    end
  end
end
