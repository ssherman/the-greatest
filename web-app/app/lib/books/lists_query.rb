module Books
  class ListsQuery < ::ListsQuery
    def self.list_type
      "Books::List"
    end
  end
end
