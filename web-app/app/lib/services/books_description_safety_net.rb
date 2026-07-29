module Services
  # Post-legacy-backfill safety net for increment b2. Any Books::Book or Books::Author with
  # a non-blank `description` column and NO Description row was created in the app rather
  # than migrated, so no legacy column speaks for it: it gets a :manual row.
  #
  # Ordering is load-bearing. "No row" is defined relative to BookDescriptionMigrator and
  # AuthorDescriptionMigrator having run, so this goes last. Run it first and it stamps
  # :manual provenance onto legacy-sourced text, which D10 exists to prevent.
  #
  # In dev this legitimately writes 0 rows: all 50 in-app-created books and all 21
  # in-app-created authors have a blank description column, and every book or author that
  # has one is covered by a non-blank legacy description (verified 2026-07-29). A total of 0
  # is a pass. Production is a different dataset, and records created between the migrator
  # run and the safety-net run are exactly what this catches.
  #
  # Reads the current database and needs no legacy connection, so -- like
  # DescriptionColumnBackfill -- this is a standalone service rather than a
  # BulkUpsertMigrator subclass. Model names are strings resolved with constantize: inside
  # `module Services`, bare Games:: and Music:: resolve to Services::Games/Services::Music,
  # and string keys sidestep that class of surprise entirely.
  #
  # insert_all, not upsert_all: ON CONFLICT DO NOTHING leaves an existing row alone, and the
  # ActiveRecord::Result#length is the count Postgres actually inserted.
  class BooksDescriptionSafetyNet
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    INSERT_BATCH = 1000
    MODEL_NAMES = ["Books::Book", "Books::Author"].freeze

    def self.call
      new.call
    end

    def call
      current_model_name = nil
      counts = MODEL_NAMES.each_with_object({}) do |model_name, acc|
        current_model_name = model_name
        acc[model_name] = backfill(model_name)
      end
      Result.new(success?: true, data: {counts: counts, total: counts.values.sum}, errors: [])
    rescue => e
      failed_model = current_model_name || "books description safety net"
      Result.new(success?: false, data: {}, errors: ["#{failed_model} safety net failed: #{e.message}"])
    end

    private

    def backfill(model_name)
      written = 0
      buffer = []

      undescribed(model_name).find_each(batch_size: INSERT_BATCH) do |record|
        content = record.description.presence
        next if content.nil?

        buffer << row_for(model_name, record, content)
        if buffer.size >= INSERT_BATCH
          written += flush(buffer)
          buffer = []
        end
      end

      written += flush(buffer) if buffer.any?
      written
    end

    # A NOT IN subquery rather than where.missing(:descriptions): the Describable
    # association carries an `order(:id)` scope, and keeping the join out of it leaves
    # find_each's batch ordering unambiguous. describable_id is NOT NULL, so there is no
    # NOT IN NULL trap.
    def undescribed(model_name)
      described_ids = Description.where(describable_type: model_name).select(:describable_id)
      model_name.constantize
        .where.not(description: [nil, ""])
        .where.not(id: described_ids)
    end

    def row_for(model_name, record, content)
      {
        describable_type: model_name,
        describable_id: record.id,
        kind: :summary,
        locale: "en",
        source: :manual,
        content: content,
        rank: :normal
      }
    end

    def flush(rows)
      Description.insert_all(rows, unique_by: :index_descriptions_on_describable_and_key).length
    end
  end
end
