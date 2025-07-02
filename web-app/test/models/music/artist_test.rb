require "test_helper"

module Music
  class ArtistTest < ActiveSupport::TestCase
    def setup
      @person = music_artists(:david_bowie)
      @band = music_artists(:pink_floyd)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @person.valid?
      assert @band.valid?
    end

    test "should require name" do
      @person.name = nil
      assert_not @person.valid?
      assert_includes @person.errors[:name], "can't be blank"
    end

    test "should set slug from name" do
      artist = Music::Artist.new(name: "Test Artist", kind: :person)
      artist.save!
      assert_equal "test-artist", artist.slug
    end

    test "should require kind" do
      @person.kind = nil
      assert_not @person.valid?
      assert_includes @person.errors[:kind], "can't be blank"
    end

    test "should validate country length" do
      @person.country = "USA"
      assert_not @person.valid?
      assert_includes @person.errors[:country], "is the wrong length (should be 2 characters)"
    end

    test "should accept valid country code" do
      @person.country = "US"
      assert @person.valid?
    end

    # Date consistency validations
    test "person cannot have band dates" do
      @person.formed_on = Date.current
      assert_not @person.valid?
      assert_includes @person.errors[:formed_on], "cannot be set for a person"

      @person.formed_on = nil
      @person.disbanded_on = Date.current
      assert_not @person.valid?
      assert_includes @person.errors[:disbanded_on], "cannot be set for a person"
    end

    test "band cannot have person dates" do
      @band.born_on = Date.current
      assert_not @band.valid?
      assert_includes @band.errors[:born_on], "cannot be set for a band"

      @band.born_on = nil
      @band.died_on = Date.current
      assert_not @band.valid?
      assert_includes @band.errors[:died_on], "cannot be set for a band"
    end

    # Enums
    test "should have correct enum values" do
      assert_equal "person", @person.kind
      assert_equal "band", @band.kind
    end

    test "should respond to enum methods" do
      assert @person.person?
      assert_not @person.band?
      assert @band.band?
      assert_not @band.person?
    end

    # Scopes
    test "people scope" do
      people = Music::Artist.people
      assert_includes people, @person
      assert_not_includes people, @band
    end

    test "bands scope" do
      bands = Music::Artist.bands
      assert_includes bands, @band
      assert_not_includes bands, @person
    end

    test "active scope" do
      @band.disbanded_on = Date.current
      @band.save!

      active_bands = Music::Artist.active
      assert_not_includes active_bands, @band
      assert_includes active_bands, @person
    end

    # FriendlyId
    test "should find by slug" do
      found = Music::Artist.friendly.find(@person.slug)
      assert_equal @person, found
    end
  end
end
