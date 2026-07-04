module Services
  module BooksMigration
    # Legacy `languages` row -> new Language attributes. The new schema has no
    # description; only the name carries over (iso codes are absent in legacy).
    class LanguageTransformer
      def self.call(attrs)
        {name: attrs["name"]}
      end
    end
  end
end
