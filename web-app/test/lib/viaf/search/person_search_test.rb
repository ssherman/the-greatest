# frozen_string_literal: true

require "test_helper"

class Viaf::Search::PersonSearchTest < ActiveSupport::TestCase
  def setup
    @client = mock("client")
    @search = Viaf::Search::PersonSearch.new(@client)
  end

  # Namespace prefixes increment per result: ns2 for the first, ns3 for the second.
  def record(prefix, viaf_id, name)
    {
      "recordData" => {
        "#{prefix}:VIAFCluster" => {
          "#{prefix}:viafID" => viaf_id,
          "#{prefix}:nameType" => "Personal",
          "#{prefix}:mainHeadings" => {
            "#{prefix}:mainHeadingEl" => [{
              "#{prefix}:sources" => {"#{prefix}:s" => "LC"},
              "#{prefix}:datafield" => {"#{prefix}:subfield" => [{"code" => "a", "content" => name}]}
            }]
          }
        }
      }
    }
  end

  def response(records, count: nil)
    {
      success: true,
      data: {
        "searchRetrieveResponse" => {
          "numberOfRecords" => {"content" => count || Array(records).size},
          "records" => {"record" => records}
        }
      },
      errors: [],
      metadata: {}
    }
  end

  test "builds a CQL personal-names query" do
    @client.expects(:get).with("viaf/search", {
      query: 'local.personalNames all "leo tolstoy"',
      maximumRecords: 10,
      sortKey: "holdingscount"
    }).returns(response([]))

    @search.call("leo tolstoy")
  end

  test "honours the limit" do
    @client.expects(:get).with("viaf/search", has_entry(maximumRecords: 3)).returns(response([]))

    @search.call("tolstoy", limit: 3)
  end

  test "escapes double quotes in the query" do
    @client.expects(:get).with(
      "viaf/search",
      has_entry(query: 'local.personalNames all "the \\"great\\" author"')
    ).returns(response([]))

    @search.call('the "great" author')
  end

  test "returns Person objects" do
    @client.stubs(:get).returns(response([record("ns2", 96987389, "Tolstoy, Leo")]))

    results = @search.call("tolstoy")

    assert_equal 1, results.size
    assert_instance_of Viaf::Person, results.first
    assert_equal "96987389", results.first.viaf_id
    assert_equal "Tolstoy, Leo", results.first.preferred_name
  end

  # ns2 for record 1, ns3 for record 2. A /^ns\d+:/ regex handles this, but the
  # normalizer must not assume the prefix is identical across records.
  test "handles incrementing namespace prefixes across records" do
    @client.stubs(:get).returns(response([
      record("ns2", 96987389, "Tolstoy, Leo"),
      record("ns3", 102333412, "Austen, Jane")
    ]))

    results = @search.call("authors")

    assert_equal %w[96987389 102333412], results.map(&:viaf_id)
    assert_equal ["Tolstoy, Leo", "Austen, Jane"], results.map(&:preferred_name)
  end

  # records.record is an object for one hit and an array for several.
  test "handles a single record arriving unwrapped" do
    @client.stubs(:get).returns(response(record("ns2", 96987389, "Tolstoy, Leo")))

    results = @search.call("tolstoy")

    assert_equal 1, results.size
    assert_equal "96987389", results.first.viaf_id
  end

  test "returns an empty array when nothing matched" do
    @client.stubs(:get).returns(
      {success: true, data: {"searchRetrieveResponse" => {
        "numberOfRecords" => {"content" => 0}
      }}, errors: [], metadata: {}}
    )

    assert_empty @search.call("zzzznotanauthor")
  end

  test "skips records that fail to distill rather than aborting the search" do
    @client.stubs(:get).returns(response([
      {"recordData" => {"ns2:something" => "unusable"}},
      record("ns3", 102333412, "Austen, Jane")
    ]))

    results = @search.call("authors")

    assert_equal ["102333412"], results.map(&:viaf_id)
  end

  test "raises ParseError when the response body is not a Hash" do
    @client.stubs(:get).returns({success: true, data: [], errors: [], metadata: {}})

    assert_raises(Viaf::Exceptions::ParseError) { @search.call("tolstoy") }
  end

  test "skips a record that is not a Hash rather than raising" do
    @client.stubs(:get).returns(response([
      "not-a-hash",
      record("ns3", 102333412, "Austen, Jane")
    ]))

    results = @search.call("authors")

    assert_equal ["102333412"], results.map(&:viaf_id)
  end

  # VIAF has been observed emitting viafID in scientific notation, which Ruby
  # parses as a Float and coerces back to the WRONG integer (off by ~27,000
  # for this value). Unlike Cluster, PersonSearch has no requested id to fall
  # back on, so a Float id means the record is corrupt: skip it, exactly like
  # a record that fails to distill, without dropping the rest of the response.
  test "excludes a record whose viafID arrived as a Float, but keeps other records" do
    float_id_record = {
      "recordData" => {
        "ns2:VIAFCluster" => {
          "ns2:viafID" => 2.71711845065478e+19,
          "ns2:nameType" => "Personal"
        }
      }
    }

    @client.stubs(:get).returns(response([
      float_id_record,
      record("ns3", 102333412, "Austen, Jane")
    ]))

    results = @search.call("authors")

    assert_equal ["102333412"], results.map(&:viaf_id)
  end

  test "raises ArgumentError for a blank name" do
    assert_raises(ArgumentError) { @search.call("") }
    assert_raises(ArgumentError) { @search.call(nil) }
  end

  test "propagates BlockedError from the client" do
    @client.stubs(:get).raises(Viaf::Exceptions::BlockedError.new("blocked", 403, "<html>"))

    assert_raises(Viaf::Exceptions::BlockedError) { @search.call("tolstoy") }
  end

  # The brief's own "skips records that fail to distill" fixture never reaches
  # Distiller.call: it has no viafID, so person_from's `viaf_id.nil?` guard
  # already returns nil before Distiller is invoked. This record has a viafID
  # (so it clears that guard) but also a redirect/directto marker nested under
  # VIAFCluster, which makes Distiller.call raise AbandonedRecordError -- this
  # is what actually exercises the `rescue Exceptions::Error` clause.
  test "skips a record that raises while being distilled, not just one missing a viafID" do
    withdrawn = {
      "recordData" => {
        "ns2:VIAFCluster" => {
          "ns2:viafID" => 5,
          "ns2:redirect" => {"ns2:directto" => "999"}
        }
      }
    }

    @client.stubs(:get).returns(response([
      withdrawn,
      record("ns3", 102333412, "Austen, Jane")
    ]))

    results = @search.call("authors")

    assert_equal ["102333412"], results.map(&:viaf_id)
  end
end
