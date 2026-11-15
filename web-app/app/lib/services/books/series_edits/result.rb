# frozen_string_literal: true

module Services
  module Books
    # Series admin edits (delete, merge, and the services built on them). Named
    # SeriesEdits, not Series, so it can't shadow ::Books::Series inside Services::Books.
    module SeriesEdits
      # One shared result for every SeriesEdits service. code is :not_found or
      # :unprocessable on failure.
      Result = Struct.new(:success?, :data, :errors, :code, keyword_init: true)
    end
  end
end
