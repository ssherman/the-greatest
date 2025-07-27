require "test_helper"

class IdentifierServiceTest < ActiveSupport::TestCase
  def setup
    @david_bowie = music_artists(:david_bowie)
    @pink_floyd = music_artists(:pink_floyd)
    @dark_side = music_albums(:dark_side_of_the_moon)
  end

  # add_identifier tests
  test "add_identifier successfully creates identifier" do
    result = IdentifierService.add_identifier(@david_bowie, :music_allmusic_artist_id, "mn0000362836")

    assert result.success?
    assert_instance_of Identifier, result.data
    assert_equal @david_bowie, result.data.identifiable
    assert result.data.music_allmusic_artist_id?
    assert_equal "mn0000362836", result.data.value
    assert_empty result.errors
  end

  test "add_identifier works with string identifier type" do
    result = IdentifierService.add_identifier(@david_bowie, "music_allmusic_artist_id", "mn0000362836")

    assert result.success?
    assert result.data.music_allmusic_artist_id?
  end

  test "add_identifier strips whitespace from value" do
    result = IdentifierService.add_identifier(@david_bowie, :music_allmusic_artist_id, "  mn0000362836  ")

    assert result.success?
    assert_equal "mn0000362836", result.data.value
  end

  test "add_identifier fails with invalid identifier type" do
    result = IdentifierService.add_identifier(@david_bowie, :invalid_type, "test-value")

    refute result.success?
    assert_nil result.data
    assert_includes result.errors.first, "invalid_type"
  end

  test "add_identifier fails with duplicate identifier" do
    # Create first identifier
    IdentifierService.add_identifier(@david_bowie, :music_musicbrainz_artist_id, "duplicate-mbid")

    # Try to create duplicate
    result = IdentifierService.add_identifier(@david_bowie, :music_musicbrainz_artist_id, "duplicate-mbid")

    refute result.success?
    assert_nil result.data
    assert_includes result.errors.join, "has already been taken"
  end

  test "add_identifier allows same value for different objects" do
    result1 = IdentifierService.add_identifier(@david_bowie, :music_discogs_artist_id, "shared-value")
    result2 = IdentifierService.add_identifier(@pink_floyd, :music_discogs_artist_id, "shared-value")

    assert result1.success?
    assert result2.success?
    assert_equal "shared-value", result1.data.value
    assert_equal "shared-value", result2.data.value
  end

  # find_by_identifier tests
  test "find_by_identifier returns object when identifier exists" do
    result = IdentifierService.find_by_identifier(:music_musicbrainz_artist_id, "5441c29d-3602-4898-b1a1-b77fa23b8e50")

    assert_equal @david_bowie, result
  end

  test "find_by_identifier works with string identifier type" do
    result = IdentifierService.find_by_identifier("music_musicbrainz_artist_id", "5441c29d-3602-4898-b1a1-b77fa23b8e50")

    assert_equal @david_bowie, result
  end

  test "find_by_identifier strips whitespace from value" do
    result = IdentifierService.find_by_identifier(:music_musicbrainz_artist_id, "  5441c29d-3602-4898-b1a1-b77fa23b8e50  ")

    assert_equal @david_bowie, result
  end

  test "find_by_identifier returns nil when identifier does not exist" do
    result = IdentifierService.find_by_identifier(:music_musicbrainz_artist_id, "nonexistent-mbid")

    assert_nil result
  end

  test "find_by_identifier returns nil for invalid identifier type" do
    result = IdentifierService.find_by_identifier(:invalid_type, "test-value")

    assert_nil result
  end

  # find_by_identifier_in_domain tests
  test "find_by_identifier_in_domain returns object when identifier exists in domain" do
    result = IdentifierService.find_by_identifier_in_domain(
      "Music::Artist",
      :music_musicbrainz_artist_id,
      "5441c29d-3602-4898-b1a1-b77fa23b8e50"
    )

    assert_equal @david_bowie, result
  end

  test "find_by_identifier_in_domain returns nil when identifier exists but in different domain" do
    result = IdentifierService.find_by_identifier_in_domain(
      "Music::Album",
      :music_musicbrainz_artist_id,
      "5441c29d-3602-4898-b1a1-b77fa23b8e50"
    )

    assert_nil result
  end

  test "find_by_identifier_in_domain works with string identifier type" do
    result = IdentifierService.find_by_identifier_in_domain(
      "Music::Artist",
      "music_musicbrainz_artist_id",
      "5441c29d-3602-4898-b1a1-b77fa23b8e50"
    )

    assert_equal @david_bowie, result
  end

  # find_by_value_in_domain tests
  test "find_by_value_in_domain returns object when value exists in domain" do
    result = IdentifierService.find_by_value_in_domain("Music::Artist", "5441c29d-3602-4898-b1a1-b77fa23b8e50")

    assert_equal @david_bowie, result
  end

  test "find_by_value_in_domain returns nil when value exists but in different domain" do
    result = IdentifierService.find_by_value_in_domain("Music::Album", "5441c29d-3602-4898-b1a1-b77fa23b8e50")

    assert_nil result
  end

  test "find_by_value_in_domain strips whitespace from value" do
    result = IdentifierService.find_by_value_in_domain("Music::Artist", "  5441c29d-3602-4898-b1a1-b77fa23b8e50  ")

    assert_equal @david_bowie, result
  end

  test "find_by_value_in_domain handles ISBN use case" do
    # Simulate book with multiple ISBN formats
    # This would work better with actual book fixtures, but demonstrates the concept
    IdentifierService.add_identifier(@david_bowie, :music_musicbrainz_artist_id, "isbn-test-value")
    IdentifierService.add_identifier(@david_bowie, :music_discogs_artist_id, "isbn-test-value")

    # Should find the first one that matches the value regardless of type
    result = IdentifierService.find_by_value_in_domain("Music::Artist", "isbn-test-value")

    assert_equal @david_bowie, result
  end

  # resolve_identifiers tests
  test "resolve_identifiers returns all identifiers for object" do
    identifiers = IdentifierService.resolve_identifiers(@david_bowie)

    assert_includes identifiers, identifiers(:david_bowie_musicbrainz)
    assert_includes identifiers, identifiers(:david_bowie_discogs)
    refute_includes identifiers, identifiers(:pink_floyd_musicbrainz)
  end

  test "resolve_identifiers returns empty collection for object with no identifiers" do
    # Create a new artist with no identifiers
    new_artist = Music::Artist.create!(name: "Test Artist", slug: "test-artist", kind: :person)
    identifiers = IdentifierService.resolve_identifiers(new_artist)

    assert_empty identifiers
  end

  test "resolve_identifiers orders by identifier_type" do
    # Add another identifier to ensure ordering
    IdentifierService.add_identifier(@david_bowie, :music_allmusic_artist_id, "test-allmusic-id")

    identifiers = IdentifierService.resolve_identifiers(@david_bowie)

    # Should be ordered by identifier_type (enum values: musicbrainz=100, discogs=102, allmusic=103)
    types = identifiers.map(&:identifier_type)
    expected_order = ["music_musicbrainz_artist_id", "music_discogs_artist_id", "music_allmusic_artist_id"]
    assert_equal expected_order, types
  end

  # identifier_exists? tests
  test "identifier_exists? returns true when identifier exists" do
    result = IdentifierService.identifier_exists?(:music_musicbrainz_artist_id, "5441c29d-3602-4898-b1a1-b77fa23b8e50")

    assert result
  end

  test "identifier_exists? returns false when identifier does not exist" do
    result = IdentifierService.identifier_exists?(:music_musicbrainz_artist_id, "nonexistent-mbid")

    refute result
  end

  test "identifier_exists? works with string identifier type" do
    result = IdentifierService.identifier_exists?("music_musicbrainz_artist_id", "5441c29d-3602-4898-b1a1-b77fa23b8e50")

    assert result
  end

  test "identifier_exists? strips whitespace from value" do
    result = IdentifierService.identifier_exists?(:music_musicbrainz_artist_id, "  5441c29d-3602-4898-b1a1-b77fa23b8e50  ")

    assert result
  end

  test "identifier_exists? returns false for invalid identifier type" do
    result = IdentifierService.identifier_exists?(:invalid_type, "test-value")

    refute result
  end

  # Integration tests
  test "complete workflow: add, find, check existence" do
    # Add identifier
    add_result = IdentifierService.add_identifier(@pink_floyd, :music_allmusic_artist_id, "mn0000362837")
    assert add_result.success?

    # Check existence
    exists = IdentifierService.identifier_exists?(:music_allmusic_artist_id, "mn0000362837")
    assert exists

    # Find by identifier
    found_object = IdentifierService.find_by_identifier(:music_allmusic_artist_id, "mn0000362837")
    assert_equal @pink_floyd, found_object

    # Find in domain
    found_in_domain = IdentifierService.find_by_identifier_in_domain("Music::Artist", :music_allmusic_artist_id, "mn0000362837")
    assert_equal @pink_floyd, found_in_domain

    # Resolve all identifiers
    all_identifiers = IdentifierService.resolve_identifiers(@pink_floyd)
    assert_includes all_identifiers.map(&:value), "mn0000362837"
  end

  test "cross-domain identifier isolation" do
    # Add same identifier type and value to different domains
    IdentifierService.add_identifier(@david_bowie, :music_asin, "B000001234")
    IdentifierService.add_identifier(@dark_side, :music_asin, "B000001234")

    # Should find different objects based on domain
    artist_result = IdentifierService.find_by_identifier_in_domain("Music::Artist", :music_asin, "B000001234")
    album_result = IdentifierService.find_by_identifier_in_domain("Music::Album", :music_asin, "B000001234")

    assert_equal @david_bowie, artist_result
    assert_equal @dark_side, album_result
  end

  test "handles edge cases gracefully" do
    # Empty string value
    result = IdentifierService.add_identifier(@david_bowie, :music_allmusic_artist_id, "")
    refute result.success?

    # Nil value (converted to string)
    result = IdentifierService.add_identifier(@david_bowie, :music_allmusic_artist_id, nil)
    refute result.success?

    # Very long value
    long_value = "a" * 256
    result = IdentifierService.add_identifier(@david_bowie, :music_allmusic_artist_id, long_value)
    refute result.success?
  end
end
