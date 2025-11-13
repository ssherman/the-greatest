require "test_helper"

module Actions
  module Admin
    module Music
      class BulkCalculateWeightsTest < ActiveSupport::TestCase
        setup do
          @user = users(:admin_user)
          @ranking_config1 = ranking_configurations(:music_albums_global)
          @ranking_config2 = ranking_configurations(:music_albums_secondary)
        end

        # Metadata Tests

        test "name returns correct action name" do
          assert_equal "Bulk Calculate Weights", BulkCalculateWeights.name
        end

        test "message returns correct description" do
          assert_equal "Recalculate weights for all ranked lists in the selected configurations.", BulkCalculateWeights.message
        end

        test "visible? returns true when view is index" do
          assert BulkCalculateWeights.visible?(view: :index)
        end

        test "visible? returns true when view is show" do
          assert BulkCalculateWeights.visible?(view: :show)
        end

        test "visible? returns false when view is not provided" do
          assert_not BulkCalculateWeights.visible?({})
        end

        # Call Tests

        test "returns error when no models provided" do
          action = BulkCalculateWeights.new(user: @user, models: [])
          result = action.call

          assert_not result.success?
          assert_equal "No configurations selected.", result.message
        end

        test "enqueues job for each configuration" do
          BulkCalculateWeightsJob.expects(:perform_async).with(@ranking_config1.id)
          BulkCalculateWeightsJob.expects(:perform_async).with(@ranking_config2.id)

          action = BulkCalculateWeights.new(user: @user, models: [@ranking_config1, @ranking_config2])
          result = action.call

          assert result.success?
        end

        test "returns success message with count of configurations" do
          BulkCalculateWeightsJob.stubs(:perform_async)

          action = BulkCalculateWeights.new(user: @user, models: [@ranking_config1, @ranking_config2])
          result = action.call

          assert result.success?
          assert_equal "Weight calculation queued for 2 configurations.", result.message
        end

        test "returns success message with singular form for single configuration" do
          BulkCalculateWeightsJob.stubs(:perform_async)

          action = BulkCalculateWeights.new(user: @user, models: [@ranking_config1])
          result = action.call

          assert result.success?
          assert_equal "Weight calculation queued for 1 configuration.", result.message
        end

        test "enqueues job for all configurations" do
          BulkCalculateWeightsJob.expects(:perform_async).with(@ranking_config1.id)
          BulkCalculateWeightsJob.expects(:perform_async).with(@ranking_config2.id)

          action = BulkCalculateWeights.new(user: @user, models: [@ranking_config1, @ranking_config2])
          result = action.call

          assert result.success?
          assert_equal "Weight calculation queued for 2 configurations.", result.message
        end

        test "can be called using class method" do
          BulkCalculateWeightsJob.stubs(:perform_async)

          result = BulkCalculateWeights.call(user: @user, models: [@ranking_config1])

          assert result.success?
          assert_equal "Weight calculation queued for 1 configuration.", result.message
        end
      end
    end
  end
end
