module Services
  module BooksMigration
    # Legacy `categories` row -> new Books::Category attributes. PURE (String-keyed
    # hash in -> symbol-keyed attrs out, no DB). category_type and import_source are
    # copied as RAW INTEGERS — the old and new enums assign the same integers to the
    # shared names (genre/location/subject; amazon/open_library/openai/goodreads), so
    # unlike List.status/Edition.book_binding there is no re-encoding; import_source
    # nil stays nil. slug is passed through for the migrator to preserve verbatim;
    # parent_id is resolved by the migrator (self-referential remap), not here.
    # alternative_names is NOT NULL default [], so a nil merged_category_names -> [].
    class CategoryTransformer
      def self.call(attrs)
        {
          name: attrs["name"],
          description: attrs["description"],
          category_type: attrs["category_type"],
          import_source: attrs["import_source"],
          deleted: attrs["deleted"],
          slug: attrs["slug"],
          alternative_names: Array(attrs["merged_category_names"])
        }
      end
    end
  end
end
