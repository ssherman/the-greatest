# frozen_string_literal: true

module Books
  module PublisherIntake
    # Delegates to ::Books::Isbn, which has the same semantics: 13 digits with a
    # valid check digit, an ISBN-10 converted, anything else nil.
    module Isbn
      def self.normalize(value)
        ::Books::Isbn.normalize(value)&.isbn13
      end
    end
  end
end
