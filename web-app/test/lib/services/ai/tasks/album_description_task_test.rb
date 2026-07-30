# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      module Music
        class AlbumDescriptionTaskTest < ActiveSupport::TestCase
          def setup
            @album = music_albums(:dark_side_of_the_moon)
            @task = AlbumDescriptionTask.new(parent: @album)
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

          test "process_and_persist updates album description when provided" do
            provider_response = {
              parsed: {
                description: "The Dark Side of the Moon is Pink Floyd's groundbreaking concept album exploring themes of conflict and mental illness.",
                abstained: false,
                abstain_reason: nil
              }
            }

            # Mock the chat object
            chat = mock
            @task.stubs(:chat).returns(chat)

            result = @task.send(:process_and_persist, provider_response)

            assert result.success?
            row = @album.descriptions.reload.find_by(source: :ai_generated)
            assert_equal "The Dark Side of the Moon is Pink Floyd's groundbreaking concept album exploring themes of conflict and mental illness.", row.content
            assert_equal "summary", row.kind
            assert_equal "en", row.locale
            assert_equal chat, result.ai_chat
          end

          test "process_and_persist does not write the description column" do
            provider_response = {
              parsed: {
                description: "A new AI description.",
                abstained: false,
                abstain_reason: nil
              }
            }
            original_column = @album.description

            @task.send(:process_and_persist, provider_response)

            assert_equal original_column, @album.reload.description
          end

          # Regression: the old parent.update!(description:) clobbered whatever was there.
          test "process_and_persist leaves a preferred manual description untouched" do
            album = music_albums(:animals)
            manual = album.descriptions.create!(
              kind: :summary, locale: "en", source: :manual,
              content: "Hand-written by an editor.", rank: :preferred
            )
            task = AlbumDescriptionTask.new(parent: album)
            provider_response = {
              parsed: {
                description: "AI text that must not win.",
                abstained: false,
                abstain_reason: nil
              }
            }

            task.send(:process_and_persist, provider_response)

            manual.reload
            assert_equal "Hand-written by an editor.", manual.content
            assert_equal "preferred", manual.rank
            assert_equal "AI text that must not win.",
              album.descriptions.reload.find_by(source: :ai_generated).content
            assert_equal manual, album.primary_description
          end

          test "process_and_persist does not update when abstained" do
            original_content = @album.descriptions.find_by(source: :ai_generated).content
            provider_response = {
              parsed: {
                description: "Text the AI abstained on.",
                abstained: true,
                abstain_reason: "Not familiar with this album"
              }
            }

            chat = mock
            @task.stubs(:chat).returns(chat)

            result = @task.send(:process_and_persist, provider_response)

            assert result.success?
            assert_equal original_content, @album.descriptions.reload.find_by(source: :ai_generated).content
          end

          test "process_and_persist does not update when description is blank" do
            original_content = @album.descriptions.find_by(source: :ai_generated).content
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
            assert_equal original_content, @album.descriptions.reload.find_by(source: :ai_generated).content
          end

          test "ResponseSchema has correct structure" do
            schema = AlbumDescriptionTask::ResponseSchema

            # OpenAI::BaseModel uses the full class name
            assert_includes schema.name, "ResponseSchema"
            assert schema < OpenAI::BaseModel
          end

          test "task accepts custom provider and model" do
            task = AlbumDescriptionTask.new(
              parent: @album,
              provider: :anthropic,
              model: "claude-3-5-sonnet-20241022"
            )

            # The custom provider/model would be handled by the parent class
            # We just verify the task can be instantiated with these params
            assert_equal @album, task.send(:parent)
          end
        end
      end
    end
  end
end
