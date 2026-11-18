# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module PublisherIntake
      class ReleaseBaselineTest < ActiveSupport::TestCase
        def listing(key, source: "release_test_source", state: :baseline)
          ::Books::PublisherListing.create!(source: source, url: "https://x.test/#{source}/#{key}", external_key: key, state: state,
            first_seen_at: Time.current, last_seen_at: Time.current)
        end

        def state_of(record) = record.reload.state

        test "releases the highest external keys first, up to the limit" do
          low, mid, high = listing("9780000000001"), listing("9780000000002"), listing("9780000000003")

          result = ReleaseBaseline.call(source: "release_test_source", limit: 2)

          assert_equal 2, result.data[:released]
          assert_equal %w[baseline pending pending], [low, mid, high].map { |l| state_of(l) }
        end

        test "leaves other sources and other states alone" do
          other_source = listing("9780000000009", source: "release_other_source")
          read = listing("9780000000008", state: :read)
          mine = listing("9780000000001")

          result = ReleaseBaseline.call(source: "release_test_source", limit: 10)

          assert_equal 1, result.data[:released]
          assert_equal %w[baseline read pending], [other_source, read, mine].map { |l| state_of(l) }
        end

        test "a zero, negative or missing limit releases nothing" do
          record = listing("9780000000001")

          assert_equal [0, 0, 0], [0, -3, nil].map { |limit| ReleaseBaseline.call(source: "release_test_source", limit: limit).data[:released] }
          assert_equal "baseline", state_of(record)
        end
      end
    end
  end
end
