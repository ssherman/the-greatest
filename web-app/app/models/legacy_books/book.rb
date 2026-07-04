module LegacyBooks
  class Book < Record
    self.table_name = "books"
  end
end
