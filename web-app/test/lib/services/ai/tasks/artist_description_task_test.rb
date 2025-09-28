# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      class ArtistDescriptionTaskTest < ActiveSupport::TestCase
        def setup
          @artist = music_artists(:pink_floyd)
          @task = ArtistDescriptionTask.new(parent: @artist)
        end

        test "task_provider returns openai" do
          assert_equal :openai, @task.send(:task_provider)
        end

        test "task_model returns gpt-5-mini" do
          assert_equal "gpt-5-mini", @task.send(:task_model)
        end

        test "temperature returns 1.0" do
          assert_equal 1.0, @task.send(:temperature)
        end

        test "response_format returns json_object" do
          assert_equal({type: "json_object"}, @task.send(:response_format))
        end

        test "system_message returns string" do
          assert @task.send(:system_message).is_a?(String)
          assert @task.send(:system_message).present?
        end

        test "user_prompt returns string" do
          assert @task.send(:user_prompt).is_a?(String)
          assert @task.send(:user_prompt).present?
        end

        test "process_and_persist updates artist description when provided" do
          provider_response = {
            parsed: {
              description: "Pink Floyd is a British progressive rock band known for their concept albums.",
              abstained: false,
              abstain_reason: nil
            }
          }

          # Mock the chat object
          chat = mock
          @task.stubs(:chat).returns(chat)

          result = @task.send(:process_and_persist, provider_response)

          assert result.success?
          @artist.reload
          assert_equal "Pink Floyd is a British progressive rock band known for their concept albums.", @artist.description
          assert_equal chat, result.ai_chat
        end

        test "process_and_persist does not update when abstained" do
          original_description = @artist.description
          provider_response = {
            parsed: {
              description: nil,
              abstained: true,
              abstain_reason: "Not enough information about this artist"
            }
          }

          chat = mock
          @task.stubs(:chat).returns(chat)

          result = @task.send(:process_and_persist, provider_response)

          assert result.success?
          @artist.reload
          assert_equal original_description, @artist.description
        end

        test "process_and_persist does not update when description is blank" do
          original_description = @artist.description
          provider_response = {
            parsed: {
              description: "",
              abstained: false,
              abstain_reason: nil
            }
          }

          chat = mock
          @task.stubs(:chat).returns(chat)

          result = @task.send(:process_and_persist, provider_response)

          assert result.success?
          @artist.reload
          assert_equal original_description, @artist.description
        end

        test "ResponseSchema has correct structure" do
          schema = ArtistDescriptionTask::ResponseSchema

          assert_equal "ArtistDescription", schema.name
          assert schema.respond_to?(:string)
          assert schema.respond_to?(:boolean)
        end

        test "task accepts custom provider and model" do
          task = ArtistDescriptionTask.new(
            parent: @artist,
            provider: :anthropic,
            model: "claude-3-5-sonnet-20241022"
          )

          # The custom provider/model would be handled by the parent class
          # We just verify the task can be instantiated with these params
          assert_equal @artist, task.send(:parent)
        end
      end
    end
  end
end
