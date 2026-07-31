module Books
  module PublicIndexing
    def self.enabled?
      ENV["BOOKS_PUBLIC_INDEXING"] == "true"
    end
  end
end
