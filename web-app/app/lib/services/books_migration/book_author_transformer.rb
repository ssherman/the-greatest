module Services
  module BooksMigration
    # Legacy `book_authors` row -> new Books::BookAuthor attributes. `role` is
    # omitted (model default :author); `credited_as` is not present in legacy.
    # book_id/author_id are the natural key, resolved by the migrator, not here.
    class BookAuthorTransformer
      def self.call(attrs)
        {position: attrs["position"]}
      end
    end
  end
end
