require "test_helper"

module Api
  module V1
    module Books
      class ListResourceTest < ActiveSupport::TestCase
        setup do
          Current.domain = :books
          # Created, not a fixture: no Books::List fixture is active, and the
          # resource's activated_at reads the column the model stamps on
          # activation.
          @list = ::Books::List.create!(
            name: "100 Novels", source: "The Guardian", url: "https://example.com/100-novels",
            description: "A century of novels.", year_published: 2015, number_of_voters: 12,
            yearly_award: false, status: :active
          )
          @list.update_column(:activated_at, Time.zone.parse("2026-09-19 08:15:00 UTC"))
        end

        test "compact shape" do
          hash = ListResource.new(@list, params: {weight: 42, item_count: 100}).to_h

          assert_equal(
            %i[id name source year_published yearly_award number_of_voters item_count weight activated_at url api_url items_api_url],
            hash.keys
          )
          assert_equal @list.id, hash[:id]
          assert_equal "100 Novels", hash[:name]
          assert_equal "The Guardian", hash[:source]
          assert_equal 2015, hash[:year_published]
          assert_equal false, hash[:yearly_award]
          assert_equal 12, hash[:number_of_voters]
          assert_equal 100, hash[:item_count]
          assert_equal 42, hash[:weight]
          assert_equal "2026-09-19T08:15:00Z", hash[:activated_at]
          assert_equal "https://dev-new.thegreatestbooks.org/lists/#{@list.id}", hash[:url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@list.id}", hash[:api_url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@list.id}/items", hash[:items_api_url]
        end

        test "full trait appends description and source_url in order" do
          hash = ListResource.new(@list, params: {weight: 42, item_count: 100}, with_traits: :full).to_h

          assert_equal(
            %i[id name source year_published yearly_award number_of_voters item_count weight activated_at url api_url items_api_url description source_url],
            hash.keys
          )
          assert_equal "A century of novels.", hash[:description]
          assert_equal "https://example.com/100-novels", hash[:source_url]
        end

        test "a list off the configuration carries an explicit null weight" do
          hash = ListResource.new(@list, params: {weight: nil, item_count: 0}).to_h

          assert hash.key?(:weight)
          assert_nil hash[:weight]
        end

        test "nullable columns render as null" do
          list = ::Books::List.create!(name: "Bare", status: :approved)

          hash = ListResource.new(list, params: {weight: nil, item_count: 0}, with_traits: :full).to_h

          assert_nil hash[:source]
          assert_nil hash[:year_published]
          assert_nil hash[:yearly_award]
          assert_nil hash[:number_of_voters]
          assert_nil hash[:activated_at]
          assert_nil hash[:description]
          assert_nil hash[:source_url]
        end

        test "weight and item_count are required" do
          assert_raises(KeyError) { ListResource.new(@list).to_h }
          assert_raises(KeyError) { ListResource.new(@list, params: {item_count: 1}).to_h }
          assert_raises(KeyError) { ListResource.new(@list, params: {weight: 1}).to_h }
        end

        test "the shape carries no editorial flags, status or weight breakdown" do
          hash = ListResource.new(@list, params: {weight: 1, item_count: 1}, with_traits: :full).to_h

          %i[status high_quality_source category_specific location_specific creator_specific estimated_quality
            voter_count_estimated voter_count_unknown voter_names_unknown calculated_weight_details raw_content
            simplified_content items_json].each do |key|
            refute hash.key?(key), key
          end
        end
      end
    end
  end
end
