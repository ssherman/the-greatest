# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Artist
      module Providers
        class AiDescriptionTest < ActiveSupport::TestCase
          def setup
            @provider = AiDescription.new
            @query = ImportQuery.new(name: "Pink Floyd")
            @artist = music_artists(:pink_floyd) # Use existing artist from fixtures
          end

          test "populate launches ArtistDescriptionJob and returns success" do
            ::Music::ArtistDescriptionJob.expects(:perform_async).with(@artist.id)

            result = @provider.populate(@artist, query: @query)

            assert result.success?
            assert_equal [:ai_description_queued], result.data_populated
          end

          test "populate returns failure when artist has no name" do
            @artist.name = nil

            result = @provider.populate(@artist, query: @query)

            refute result.success?
            assert_includes result.errors, "Artist name required for AI description"
          end

          test "populate returns failure when artist has blank name" do
            @artist.name = ""

            result = @provider.populate(@artist, query: @query)

            refute result.success?
            assert_includes result.errors, "Artist name required for AI description"
          end

          test "populate returns failure when artist is not persisted" do
            # Create a new, non-persisted artist
            unpersisted_artist = ::Music::Artist.new(name: "New Artist")

            result = @provider.populate(unpersisted_artist, query: @query)

            refute result.success?
            assert_includes result.errors, "Artist must be persisted before queuing AI description job"
          end

          test "populate works with item-based import when query is nil" do
            ::Music::ArtistDescriptionJob.expects(:perform_async).with(@artist.id)

            result = @provider.populate(@artist, query: nil)

            assert result.success?
            assert_equal [:ai_description_queued], result.data_populated
          end
        end
      end
    end
  end
end
