module Services
  module BooksMigration
    # data_migration:sync (spec §5): brings over only what is new on legacy, in
    # :all's dependency order, then queues search indexing for what it inserted and
    # advances the watermarks. Any failed step stops the run with the watermarks
    # unchanged; every step is insert-only here, so the next run retries safely.
    # The user-data steps join after news_posts in increment 3 (spec §6).
    class Sync
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(final: false, legacy: LegacySource.new)
        new(final: final, legacy: legacy).call
      end

      def initialize(final:, legacy:)
        @final = final
        @legacy = legacy
      end

      def call
        plan = SyncPlan.build(final: @final, legacy: @legacy)
        return failure(plan, [], "run data_migration:sync_init first (no sync watermarks)") unless plan.initialized?

        outcomes = []
        steps(plan.scope).each do |label, step|
          outcome = begin
            step.call
          rescue => e
            outcomes << [label, e.message]
            return failure(plan, outcomes, "#{label} raised: #{e.message}")
          end
          outcomes << [label, outcome]
          return failure(plan, outcomes, "#{label} failed: #{error_of(outcome)}") unless succeeded?(outcome)
        end

        indexed = queue_search_indexing(plan.scope)
        advance_watermarks(plan.next_watermarks)
        Result.new(success?: true, data: {plan: plan, steps: outcomes, indexed: indexed}, errors: [])
      end

      private

      def steps(scope)
        [
          ["languages", -> { LanguageMigrator.call(sync: scope) }],
          ["users", -> { UserMigrator.call }],
          ["authors", -> { AuthorMigrator.call(sync: scope) }],
          ["books", -> { BookMigrator.call(sync: scope) }],
          ["book_authors", -> { BookAuthorMigrator.call(sync: scope) }],
          ["editions", -> { EditionMigrator.call(sync: scope) }],
          ["book_identifiers", -> { BookIdentifierMigrator.call(sync: scope) }],
          ["book_work_identifiers", -> { BookWorkIdentifierMigrator.call(sync: scope) }],
          ["author_identifiers", -> { AuthorIdentifierMigrator.call(sync: scope) }],
          ["edition_identifiers", -> { EditionIdentifierMigrator.call(sync: scope) }],
          ["edition_isbn_identifiers", -> { EditionIsbnIdentifierMigrator.call(sync: scope) }],
          ["edition_amazon_identifiers", -> { ::Services::Books::EditionIdentifierBackfill.call(book_ids: scope.book_ids.to_a) }],
          ["categories", -> { CategoryMigrator.call(sync: scope) }],
          ["category_items", -> { CategoryItemMigrator.call(sync: scope) }],
          ["book_attributes", -> { BookAttributesMigrator.call(sync: scope) }],
          ["book_type_categories", -> { BookTypeCategoryMigrator.call(sync: scope) }],
          ["countries", -> { CountryMigrator.call(sync: scope) }],
          ["author_countries", -> { AuthorCountryMigrator.call(sync: scope) }],
          ["book_countries", -> { BookCountryMigrator.call(sync: scope) }],
          ["external_links", -> { ExternalLinkMigrator.call(sync: scope) }],
          ["book_descriptions", -> { BookDescriptionMigrator.call(sync: scope) }],
          ["author_descriptions", -> { AuthorDescriptionMigrator.call(sync: scope) }],
          ["description_safety_net", -> { ::Services::BooksDescriptionSafetyNet.call }],
          ["news_posts", -> { NewsPostMigrator.call }],
          ["book_images", -> { BookImageMigrator.call(sync: scope) }]
        ]
      end

      # The migrators return a Hash, the older services a Result, and the edition
      # backfill a count.
      def succeeded?(outcome)
        case outcome
        when Hash then outcome[:success]
        when Integer then true
        else outcome.success?
        end
      end

      def error_of(outcome)
        outcome.is_a?(Hash) ? outcome[:error] : Array(outcome.errors).join("; ")
      end

      # The migrators load with indexing suppressed (spec §5), so the run indexes
      # what it inserted. Ids are read back from the table, which also covers books
      # a failed earlier run inserted.
      def queue_search_indexing(scope)
        inserted = {
          "Books::Book" => ::Books::Book.where(id: scope.book_ids.to_a).pluck(:id),
          "Books::Author" => ::Books::Author.where(id: scope.author_ids.to_a).pluck(:id)
        }
        rows = inserted.flat_map do |type, ids|
          ids.map { |id| {parent_type: type, parent_id: id, action: SearchIndexRequest.actions[:index_item]} }
        end
        SearchIndexRequest.insert_all(rows) if rows.any?
        inserted.transform_values(&:size)
      end

      def advance_watermarks(values)
        LegacySyncWatermark.transaction do
          values.each { |key, value| LegacySyncWatermark.find_by!(key: key).update!(value: value) }
        end
      end

      def failure(plan, outcomes, message)
        Result.new(success?: false, data: {plan: plan, steps: outcomes, indexed: {}}, errors: [message])
      end
    end
  end
end
