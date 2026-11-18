# frozen_string_literal: true

module Books
  module PublisherIntake
    # outcome: :ok | :blocked | :unavailable | :unparseable.
    # requests are follow-ups (sitemap children, the next API page).
    Discovery = Data.define(:outcome, :listings, :requests)
  end
end
