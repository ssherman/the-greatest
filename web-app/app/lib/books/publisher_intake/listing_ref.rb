# frozen_string_literal: true

module Books
  module PublisherIntake
    # One URL found during discovery.
    ListingRef = Data.define(:url, :external_key, :signal)
  end
end
