# frozen_string_literal: true

require "test_helper"

class Viaf::ClusterTest < ActiveSupport::TestCase
  def setup
    @client = mock("client")
    @cluster = Viaf::Cluster.new(@client)
  end

  def raw_response
    {
      success: true,
      data: {
        "ns1:VIAFCluster" => {
          "ns1:viafID" => 96987389,
          "ns1:nameType" => "Personal",
          "ns1:birthDate" => "1828-09-09",
          "ns1:deathDate" => "1910-11-20",
          "ns1:fixed" => {"ns1:gender" => "b"},
          "ns1:sources" => {"ns1:source" => [{"ns1:content" => "LC|n  79068416"}]},
          "ns1:mainHeadings" => {"ns1:mainHeadingEl" => [{
            "ns1:sources" => {"ns1:s" => "LC"},
            "ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "Tolstoy, Leo"}]}
          }]}
        }
      },
      errors: [],
      metadata: {}
    }
  end

  test "fetches, distills, and returns a Person on a cache miss" do
    @client.expects(:get).with("viaf/96987389").returns(raw_response)

    person = @cluster.find("96987389")

    assert_instance_of Viaf::Person, person
    assert_equal "96987389", person.viaf_id
    assert_equal 1828, person.birth_year
    assert_equal "n79068416", person.lcnaf
  end

  test "writes exactly one ExternalRecord on a cache miss" do
    @client.stubs(:get).returns(raw_response)

    assert_difference "ExternalRecord.count", 1 do
      @cluster.find("96987389")
    end

    record = ExternalRecord.find_by(source: :viaf, source_id: "96987389")

    assert_equal "Personal", record.payload["name_type"]
    assert_equal Viaf::Distiller::SCHEMA_VERSION, record.schema_version
    assert_not_nil record.fetched_at
  end

  test "does not hit the network on a cache hit" do
    ExternalRecord.create!(
      source: :viaf,
      source_id: "96987389",
      payload: {"viaf_id" => "96987389", "name_type" => "Personal", "birth_date" => "1828-09-09"},
      fetched_at: Time.current
    )
    @client.expects(:get).never

    person = @cluster.find("96987389")

    assert_equal 1828, person.birth_year
  end

  test "a cache hit and a fresh fetch produce equal people" do
    @client.stubs(:get).returns(raw_response)
    fresh = @cluster.find("96987389")

    cached = Viaf::Cluster.new(@client).find("96987389")

    assert_equal fresh.viaf_id, cached.viaf_id
    assert_equal fresh.birth_year, cached.birth_year
    assert_equal fresh.lcnaf, cached.lcnaf
    assert_equal fresh.preferred_name, cached.preferred_name
  end

  test "refresh: true refetches and updates the existing row" do
    ExternalRecord.create!(
      source: :viaf, source_id: "96987389",
      payload: {"viaf_id" => "96987389", "name_type" => "Stale"},
      fetched_at: 10.days.ago
    )
    @client.expects(:get).returns(raw_response)

    assert_no_difference "ExternalRecord.count" do
      @cluster.find("96987389", refresh: true)
    end

    assert_equal "Personal", ExternalRecord.find_by(source_id: "96987389").payload["name_type"]
  end

  test "raises ArgumentError for a blank id" do
    assert_raises(ArgumentError) { @cluster.find("") }
    assert_raises(ArgumentError) { @cluster.find(nil) }
  end

  test "propagates NotFoundError and caches nothing" do
    @client.stubs(:get).raises(Viaf::Exceptions::NotFoundError.new("nope", 404, "{}"))

    assert_no_difference "ExternalRecord.count" do
      assert_raises(Viaf::Exceptions::NotFoundError) { @cluster.find("999") }
    end
  end

  test "propagates AbandonedRecordError and caches nothing" do
    @client.stubs(:get).returns(
      {success: true, data: {"ns1:scavenged" => "true"}, errors: [], metadata: {}}
    )

    assert_no_difference "ExternalRecord.count" do
      assert_raises(Viaf::Exceptions::AbandonedRecordError) { @cluster.find("999") }
    end
  end

  test "propagates BlockedError and caches nothing" do
    @client.stubs(:get).raises(Viaf::Exceptions::BlockedError.new("blocked", 403, "<html>"))

    assert_no_difference "ExternalRecord.count" do
      assert_raises(Viaf::Exceptions::BlockedError) { @cluster.find("96987389") }
    end
  end

  test "accepts an integer viaf id" do
    @client.stubs(:get).returns(raw_response)

    assert_equal "96987389", @cluster.find(96987389).viaf_id
  end
end
