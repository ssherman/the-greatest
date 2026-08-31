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

  # Rich enough to give every Person reader a distinguishing, non-nil value,
  # so the cache-hit/fresh-fetch equivalence test below cannot pass vacuously.
  def rich_raw_response
    {
      success: true,
      data: {
        "ns1:VIAFCluster" => {
          "ns1:viafID" => 96987389,
          "ns1:nameType" => "Personal",
          "ns1:birthDate" => "1828-09-09",
          "ns1:deathDate" => "1910-11-20",
          "ns1:dateType" => "lifespan",
          "ns1:fixed" => {"ns1:gender" => "b"},
          "ns1:sources" => {"ns1:source" => [
            {"ns1:content" => "LC|n  79068416"},
            {"ns1:content" => "ISNI|0000000121435636"},
            {"ns1:content" => "WKP|Q7243"}
          ]},
          "ns1:mainHeadings" => {"ns1:mainHeadingEl" => [
            {
              "ns1:sources" => {"ns1:s" => "LC"},
              "ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "Tolstoy, Leo"}]}
            },
            {
              "ns1:sources" => {"ns1:s" => "DNB"},
              "ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "Tolstoi, Lew Nikolajewitsch"}]}
            }
          ]},
          "ns1:x400s" => {"ns1:x400" => [{
            "ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "Tolstoi, Leon"}]}
          }]},
          "ns1:nationalityOfEntity" => {"ns1:data" => [{"ns1:text" => "Russian"}]},
          "ns1:languageOfEntity" => {"ns1:data" => [{"ns1:text" => "rus"}]},
          "ns1:occupation" => {"ns1:data" => [{"ns1:text" => "Novelist"}]},
          "ns1:fieldOfActivity" => {"ns1:data" => [{"ns1:text" => "Literature"}]}
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

  test "a stale schema_version is treated as a cache miss and refetched" do
    ExternalRecord.create!(
      source: :viaf,
      source_id: "96987389",
      payload: {"viaf_id" => "96987389", "name_type" => "Stale"},
      schema_version: 0,
      fetched_at: Time.current
    )
    @client.expects(:get).with("viaf/96987389").returns(raw_response)

    person = @cluster.find("96987389")

    assert_equal "Personal", person.name_type

    record = ExternalRecord.find_by(source: :viaf, source_id: "96987389")
    assert_equal Viaf::Distiller::SCHEMA_VERSION, record.schema_version
    assert_equal "Personal", record.payload["name_type"]
  end

  test "a cache hit and a fresh fetch produce equal people" do
    @client.stubs(:get).returns(rich_raw_response)
    fresh = @cluster.find("96987389")

    cached = Viaf::Cluster.new(@client).find("96987389")

    # Compare the full public reader surface as one tuple, not a handful of
    # scalars -- a partial comparison can pass while unread fields (a second
    # main_headings entry, ISNI, names, ...) silently diverge between a hit
    # and a fresh fetch.
    reader_methods = %i[
      viaf_id name_type birth_date death_date gender_code source_ids
      main_headings names nationality language occupation field_of_activity
      birth_year death_year gender kind lcnaf isni wikidata_qid preferred_name
    ]

    assert_equal reader_methods.map { |m| fresh.public_send(m) },
      reader_methods.map { |m| cached.public_send(m) }
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

  test "a losing write race does not raise and does not create a duplicate row" do
    ExternalRecord.create!(
      source: :viaf,
      source_id: "96987389",
      payload: {"viaf_id" => "96987389", "name_type" => "Winner"},
      schema_version: Viaf::Distiller::SCHEMA_VERSION,
      fetched_at: Time.current
    )
    @client.stubs(:get).returns(raw_response)
    # Simulate another worker's INSERT landing between our SELECT and our
    # INSERT: force store's lookup to miss the row that already exists, so
    # its save! collides with the real uniqueness validation / unique index.
    ExternalRecord.stubs(:find_or_initialize_by).returns(
      ExternalRecord.new(source: :viaf, source_id: "96987389")
    )

    person = nil
    assert_nothing_raised { person = @cluster.find("96987389", refresh: true) }

    assert_equal 1, ExternalRecord.where(source: :viaf, source_id: "96987389").count
    assert_instance_of Viaf::Person, person
    assert_equal "96987389", person.viaf_id
    # viaf_id is identical between the winner's stored payload and the loser's
    # freshly-fetched one; name_type is what actually distinguishes them
    # ("Winner" vs raw_response's "Personal"), proving `find` returns the
    # Person built from its own fetch rather than re-reading the winner's row.
    assert_equal "Personal", person.name_type
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
