module Services
  class DescriptionColumnBackfill
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    INSERT_BATCH = 1000

    SOURCE_BY_MODEL = {
      "Games::Game" => :igdb,
      "Games::Company" => :igdb,
      "Games::Series" => :manual,
      "Music::Album" => :ai_generated,
      "Music::Artist" => :ai_generated
    }.freeze

    def self.call
      new.call
    end

    def call
      current_model_name = nil
      counts = SOURCE_BY_MODEL.each_with_object({}) do |(model_name, source), acc|
        current_model_name = model_name
        acc[model_name] = backfill(model_name.constantize, source)
      end
      Result.new(success?: true, data: {counts: counts, total: counts.values.sum}, errors: [])
    rescue => e
      failed_model = current_model_name || "description column backfill"
      Result.new(success?: false, data: {}, errors: ["#{failed_model} backfill failed: #{e.message}"])
    end

    private

    def backfill(model, source)
      written = 0
      buffer = []

      model.where.not(description: [nil, ""]).find_each(batch_size: INSERT_BATCH) do |record|
        content = record.description.presence
        next if content.nil?

        buffer << row_for(record, source, content)
        if buffer.size >= INSERT_BATCH
          written += flush(buffer)
          buffer = []
        end
      end

      written += flush(buffer) if buffer.any?
      written
    end

    def row_for(record, source, content)
      {
        describable_type: record.class.polymorphic_name,
        describable_id: record.id,
        kind: :summary,
        locale: "en",
        source: source,
        content: content,
        rank: :normal
      }
    end

    # insert_all, not upsert_all: ON CONFLICT DO NOTHING leaves an existing row alone.
    # upsert_all would reset a human's rank: :preferred back to :normal and overwrite
    # edited content on every re-run.
    def flush(rows)
      Description.insert_all(rows, unique_by: :index_descriptions_on_describable_and_key)
      rows.size
    end
  end
end
