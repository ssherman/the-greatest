# == Schema Information
#
# Table name: music_artists
#
#  id           :bigint           not null, primary key
#  born_on      :date
#  country      :string(2)
#  description  :text
#  died_on      :date
#  disbanded_on :date
#  formed_on    :date
#  kind         :integer          default("person"), not null
#  name         :string           not null
#  slug         :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_music_artists_on_kind  (kind)
#  index_music_artists_on_slug  (slug) UNIQUE
#
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

    test "should allow description" do
      @person.description = "A legendary musician who changed the face of rock music."
      assert @person.valid?
      assert_equal "A legendary musician who changed the face of rock music.", @person.description
    end

    test "should allow empty description" do
      @person.description = nil
      assert @person.valid?
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

    # Associations
    test "should have many credits" do
      roger_waters = music_artists(:roger_waters)
      assert_respond_to roger_waters, :credits
      assert_includes roger_waters.credits, music_credits(:time_writer)
      assert_includes roger_waters.credits, music_credits(:time_composer)
    end

    # AI Integration
    test "should populate details with AI successfully" do
      # Mock the AI task
      mock_task = mock
      mock_result = mock
      mock_result.stubs(:success?).returns(true)
      mock_result.stubs(:data).returns({
        description: "Innovative English singer-songwriter",
        born_on: "1947-01-08",
        died_on: "2016-01-10",
        country: "GB",
        kind: "person"
      })

      Services::Ai::Tasks::ArtistDetailsTask.expects(:new).with(parent: @person).returns(mock_task)
      mock_task.expects(:call).returns(mock_result).with do
        # Simulate the process_and_persist behavior
        @person.update!(
          description: "Innovative English singer-songwriter",
          born_on: Date.parse("1947-01-08"),
          died_on: Date.parse("2016-01-10"),
          country: "GB",
          kind: "person"
        )
        mock_result
      end

      # Store original values
      @person.description
      @person.born_on
      @person.died_on
      @person.country
      @person.kind

      result = @person.populate_details_with_ai!

      # Verify the artist was updated
      @person.reload
      assert_equal "Innovative English singer-songwriter", @person.description
      assert_equal Date.parse("1947-01-08"), @person.born_on
      assert_equal Date.parse("2016-01-10"), @person.died_on
      assert_equal "GB", @person.country
      assert_equal "person", @person.kind

      assert result.success?
    end

    test "should handle AI task failure gracefully" do
      # Mock the AI task to fail
      mock_task = mock
      mock_result = mock
      mock_result.stubs(:success?).returns(false)
      mock_result.stubs(:error).returns("AI service unavailable")

      Services::Ai::Tasks::ArtistDetailsTask.expects(:new).with(parent: @person).returns(mock_task)
      mock_task.expects(:call).returns(mock_result)

      # Store original values
      original_description = @person.description
      original_born_on = @person.born_on
      original_died_on = @person.died_on
      original_country = @person.country
      original_kind = @person.kind

      result = @person.populate_details_with_ai!

      # Verify the artist was not updated
      @person.reload
      assert_equal original_description, @person.description
      assert_equal original_born_on, @person.born_on
      assert_equal original_died_on, @person.died_on
      assert_equal original_country, @person.country
      assert_equal original_kind, @person.kind

      refute result.success?
      assert_includes result.error, "AI service unavailable"
    end

    test "should handle AI task exceptions gracefully" do
      # Mock the AI task to raise an exception
      Services::Ai::Tasks::ArtistDetailsTask.expects(:new).with(parent: @person).raises(StandardError.new("Task creation failed"))

      # Store original values
      original_description = @person.description
      original_born_on = @person.born_on
      original_died_on = @person.died_on
      original_country = @person.country
      original_kind = @person.kind

      # Expect the exception to be raised
      assert_raises(StandardError) do
        @person.populate_details_with_ai!
      end

      # Verify the artist was not updated
      @person.reload
      assert_equal original_description, @person.description
      assert_equal original_born_on, @person.born_on
      assert_equal original_died_on, @person.died_on
      assert_equal original_country, @person.country
      assert_equal original_kind, @person.kind
    end

    test "should handle band type artists with AI" do
      # Mock the AI task for a band
      mock_task = mock
      mock_result = mock
      mock_result.stubs(:success?).returns(true)
      mock_result.stubs(:data).returns({
        description: "English progressive rock band",
        born_on: nil,
        died_on: nil,
        country: "GB",
        kind: "band"
      })

      # Ensure the mock is properly applied and simulates the full task behavior
      Services::Ai::Tasks::ArtistDetailsTask.expects(:new).with(parent: @band).returns(mock_task)
      mock_task.expects(:call).returns(mock_result).with do
        # Simulate the process_and_persist behavior
        @band.update!(
          description: "English progressive rock band",
          born_on: nil,
          died_on: nil,
          country: "GB",
          kind: "band"
        )
        mock_result
      end

      # Store original values
      @band.description
      @band.country
      @band.kind

      result = @band.populate_details_with_ai!

      # Verify the band was updated
      @band.reload
      assert_equal "English progressive rock band", @band.description
      assert_equal "GB", @band.country
      assert_equal "band", @band.kind
      assert_nil @band.born_on
      assert_nil @band.died_on

      assert result.success?
    end

    test "should handle missing optional fields from AI response" do
      # Reset description to nil to match test expectation
      @person.update!(description: nil)
      # Mock the AI task with minimal data
      mock_task = mock
      mock_result = mock
      mock_result.stubs(:success?).returns(true)
      mock_result.stubs(:data).returns({
        description: nil,
        born_on: nil,
        died_on: nil,
        country: nil,
        kind: "person"
      })

      Services::Ai::Tasks::ArtistDetailsTask.expects(:new).with(parent: @person).returns(mock_task)
      mock_task.expects(:call).returns(mock_result).with do
        # Simulate the process_and_persist behavior
        @person.update!(
          description: nil,
          born_on: nil,
          died_on: nil,
          country: nil,
          kind: "person"
        )
        mock_result
      end

      result = @person.populate_details_with_ai!

      # Verify the artist was updated with nil values for optional fields
      @person.reload
      assert_nil @person.description
      assert_nil @person.born_on
      assert_nil @person.died_on
      assert_nil @person.country
      assert_equal "person", @person.kind

      assert result.success?
    end
  end
end
