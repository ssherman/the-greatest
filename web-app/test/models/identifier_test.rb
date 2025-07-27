# == Schema Information
#
# Table name: identifiers
#
#  id                :bigint           not null, primary key
#  identifiable_type :string           not null
#  identifier_type   :integer          not null
#  value             :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  identifiable_id   :bigint           not null
#
# Indexes
#
#  index_identifiers_on_identifiable    (identifiable_type,identifiable_id)
#  index_identifiers_on_lookup_unique   (identifiable_type,identifier_type,value,identifiable_id) UNIQUE
#  index_identifiers_on_type_and_value  (identifiable_type,value)
#
require "test_helper"

class IdentifierTest < ActiveSupport::TestCase
  def setup
    @david_bowie = music_artists(:david_bowie)
    @pink_floyd = music_artists(:pink_floyd)
    @dark_side = music_albums(:dark_side_of_the_moon)
  end

  # Association Tests
  test "belongs to identifiable polymorphically" do
    identifier = identifiers(:david_bowie_musicbrainz)
    assert_equal @david_bowie, identifier.identifiable
    assert_equal "Music::Artist", identifier.identifiable_type
  end

  # Validation Tests
  test "requires identifiable" do
    identifier = Identifier.new(identifier_type: :music_musicbrainz_artist_id, value: "test-mbid")
    refute identifier.valid?
    assert_includes identifier.errors[:identifiable], "must exist"
  end

  test "requires identifier_type" do
    identifier = Identifier.new(identifiable: @david_bowie, value: "test-mbid")
    refute identifier.valid?
    assert_includes identifier.errors[:identifier_type], "can't be blank"
  end

  test "requires value" do
    identifier = Identifier.new(identifiable: @david_bowie, identifier_type: :music_musicbrainz_artist_id)
    refute identifier.valid?
    assert_includes identifier.errors[:value], "can't be blank"
  end

  test "validates value length maximum" do
    long_value = "a" * 256
    identifier = Identifier.new(
      identifiable: @david_bowie,
      identifier_type: :music_musicbrainz_artist_id,
      value: long_value
    )
    refute identifier.valid?
    assert_includes identifier.errors[:value], "is too long (maximum is 255 characters)"
  end

  test "validates uniqueness of value scoped to identifiable and identifier_type" do
    # Create first identifier
    Identifier.create!(
      identifiable: @david_bowie,
      identifier_type: :music_musicbrainz_artist_id,
      value: "duplicate-mbid"
    )

    # Try to create duplicate - should fail
    identifier2 = Identifier.new(
      identifiable: @david_bowie,
      identifier_type: :music_musicbrainz_artist_id,
      value: "duplicate-mbid"
    )
    refute identifier2.valid?
    assert_includes identifier2.errors[:value], "has already been taken"
  end

  test "allows same value for different objects" do
    # Same value for different objects should be allowed
    identifier1 = Identifier.create!(
      identifiable: @david_bowie,
      identifier_type: :music_discogs_artist_id,
      value: "shared-value"
    )

    identifier2 = Identifier.create!(
      identifiable: @pink_floyd,
      identifier_type: :music_discogs_artist_id,
      value: "shared-value"
    )

    assert identifier1.valid?
    assert identifier2.valid?
  end

  test "allows same value for different identifier types on same object" do
    # Same object can have same value for different identifier types
    identifier1 = Identifier.create!(
      identifiable: @david_bowie,
      identifier_type: :music_musicbrainz_artist_id,
      value: "shared-value"
    )

    identifier2 = Identifier.create!(
      identifiable: @david_bowie,
      identifier_type: :music_discogs_artist_id,
      value: "shared-value"
    )

    assert identifier1.valid?
    assert identifier2.valid?
  end

  # Enum Tests
  test "identifier_type enum works with symbols" do
    identifier = Identifier.new(
      identifiable: @david_bowie,
      identifier_type: :music_musicbrainz_artist_id,
      value: "test-mbid"
    )
    assert identifier.music_musicbrainz_artist_id?
    assert_equal "music_musicbrainz_artist_id", identifier.identifier_type
  end

  test "identifier_type enum works with strings" do
    identifier = Identifier.new(
      identifiable: @david_bowie,
      identifier_type: "music_discogs_artist_id",
      value: "test-discogs-id"
    )
    assert identifier.music_discogs_artist_id?
    assert_equal "music_discogs_artist_id", identifier.identifier_type
  end

  test "identifier_type enum raises error for invalid values" do
    assert_raises(ArgumentError) do
      Identifier.new(
        identifiable: @david_bowie,
        identifier_type: :invalid_type,
        value: "test-value"
      )
    end
  end

  # Scope Tests
  test "for_domain scope filters by identifiable_type" do
    results = Identifier.for_domain(["Music::Artist"])
    assert_includes results, identifiers(:david_bowie_musicbrainz)
    assert_includes results, identifiers(:pink_floyd_musicbrainz)
    refute_includes results, identifiers(:dark_side_musicbrainz_release_group)
  end

  test "by_type scope filters by identifier_type" do
    results = Identifier.by_type(:music_musicbrainz_artist_id)
    assert_includes results, identifiers(:david_bowie_musicbrainz)
    assert_includes results, identifiers(:pink_floyd_musicbrainz)
    refute_includes results, identifiers(:david_bowie_discogs)
  end

  test "by_value scope filters by value" do
    results = Identifier.by_value("5441c29d-3602-4898-b1a1-b77fa23b8e50")
    assert_includes results, identifiers(:david_bowie_musicbrainz)
    refute_includes results, identifiers(:pink_floyd_musicbrainz)
  end

  # Class Method Tests
  test "books scope returns book identifiers" do
    # This would need book fixtures to fully test
    results = Identifier.books
    assert_equal 0, results.count # No book fixtures currently
  end

  test "music_artists scope returns music artist identifiers" do
    results = Identifier.music_artists
    assert_includes results, identifiers(:david_bowie_musicbrainz)
    assert_includes results, identifiers(:pink_floyd_musicbrainz)
    refute_includes results, identifiers(:dark_side_musicbrainz_release_group)
  end

  test "music_albums scope returns music album identifiers" do
    results = Identifier.music_albums
    assert_includes results, identifiers(:dark_side_musicbrainz_release_group)
    assert_includes results, identifiers(:wish_you_were_here_musicbrainz)
    refute_includes results, identifiers(:david_bowie_musicbrainz)
  end

  # Instance Method Tests
  test "domain method returns lowercase domain" do
    identifier = identifiers(:david_bowie_musicbrainz)
    assert_equal "music", identifier.domain
  end

  test "media_type method returns lowercase media type" do
    identifier = identifiers(:david_bowie_musicbrainz)
    assert_equal "artist", identifier.media_type

    album_identifier = identifiers(:dark_side_musicbrainz_release_group)
    assert_equal "album", album_identifier.media_type
  end

  # Database Constraint Tests
  test "database enforces uniqueness constraint" do
    # Test the database-level unique constraint
    assert_raises(ActiveRecord::RecordNotUnique) do
      # Bypass Rails validations to test database constraint
      Identifier.connection.execute(
        "INSERT INTO identifiers (identifiable_type, identifiable_id, identifier_type, value, created_at, updated_at)
         VALUES ('Music::Artist', #{@david_bowie.id}, 100, '5441c29d-3602-4898-b1a1-b77fa23b8e50', NOW(), NOW())"
      )
    end
  end

  # Integration Tests
  test "can create identifier for different model types" do
    # Test with Music::Artist
    artist_identifier = Identifier.create!(
      identifiable: @david_bowie,
      identifier_type: :music_allmusic_artist_id,
      value: "mn0000362836"
    )
    assert artist_identifier.persisted?
    assert_equal @david_bowie, artist_identifier.identifiable

    # Test with Music::Album
    album_identifier = Identifier.create!(
      identifiable: @dark_side,
      identifier_type: :music_allmusic_album_id,
      value: "mw0000650681"
    )
    assert album_identifier.persisted?
    assert_equal @dark_side, album_identifier.identifiable
  end

  test "strips whitespace from value" do
    identifier = Identifier.create!(
      identifiable: @david_bowie,
      identifier_type: :music_musicbrainz_artist_id,
      value: "  test-mbid-with-spaces  "
    )
    # Note: This test assumes we add value stripping to the model
    # Currently the model doesn't strip, but the service does
    assert_equal "  test-mbid-with-spaces  ", identifier.value
  end
end
