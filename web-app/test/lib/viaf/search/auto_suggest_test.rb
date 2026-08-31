# frozen_string_literal: true

require "test_helper"

class Viaf::Search::AutoSuggestTest < ActiveSupport::TestCase
  def setup
    @client = mock("client")
    @search = Viaf::Search::AutoSuggest.new(@client)
  end

  def response(results)
    {success: true, data: {"query" => "tolstoy", "result" => results}, errors: [], metadata: {}}
  end

  test "requests the AutoSuggest endpoint with the query" do
    @client.expects(:get).with("viaf/AutoSuggest", {query: "tolstoy"}).returns(response([]))

    @search.call("tolstoy")
  end

  test "returns Suggestion objects" do
    @client.stubs(:get).returns(response([
      {"term" => "Tolstoy, Leo, graf, 1828-1910", "nametype" => "personal",
       "viafid" => "96987389", "score" => "63074", "lc" => "n79068416"}
    ]))

    results = @search.call("tolstoy")

    assert_equal 1, results.size
    assert_instance_of Viaf::Suggestion, results.first
    assert_equal "96987389", results.first.viaf_id
    assert_equal 1828, results.first.birth_year
  end

  test "returns an empty array when result is null" do
    @client.stubs(:get).returns(
      {success: true, data: {"query" => "zzz", "result" => nil}, errors: [], metadata: {}}
    )

    assert_empty @search.call("zzz")
  end

  test "returns an empty array when result is missing" do
    @client.stubs(:get).returns({success: true, data: {"query" => "zzz"}, errors: [], metadata: {}})

    assert_empty @search.call("zzz")
  end

  test "raises ArgumentError for a blank query" do
    assert_raises(ArgumentError) { @search.call("") }
    assert_raises(ArgumentError) { @search.call(nil) }
  end

  test "propagates BlockedError from the client" do
    @client.stubs(:get).raises(Viaf::Exceptions::BlockedError.new("blocked", 403, "<html>"))

    assert_raises(Viaf::Exceptions::BlockedError) { @search.call("tolstoy") }
  end
end
