module Services
  module BooksMigration
    # Fresh-id migrator: dedupes against existing new-app languages by name
    # (languages is a shared table) and records legacy_id -> new_id for later FK
    # remapping (e.g. books.original_language_id).
    class LanguageMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Language
      end

      def model_key
        "Language"
      end

      def upsert_row(attrs)
        target = LanguageTransformer.call(attrs)
        language = Language.find_or_create_by!(name: target[:name])
        LegacyIdMap.record(model: model_key, legacy_id: attrs["id"], new_id: language.id)
      end
    end
  end
end
