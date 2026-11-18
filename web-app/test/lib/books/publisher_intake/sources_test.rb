# frozen_string_literal: true

require "test_helper"

module Books
  module PublisherIntake
    class SourcesTest < ActiveSupport::TestCase
      class AlphaSource < Sources::Base
        VERSION = 1
      end

      class BetaSource < Sources::Base
        VERSION = 1
      end

      setup do
        @original = Rails.application.config.x.publisher_intake.enabled_sources
      end

      teardown do
        Rails.application.config.x.publisher_intake.enabled_sources = @original
      end

      test "fetch of an unknown key is nil" do
        assert_nil Sources.fetch("nope")
      end

      test "fetch of a registered key is a strategy instance" do
        Sources.stubs(:registry).returns({"alpha" => AlphaSource})

        assert_instance_of AlphaSource, Sources.fetch("alpha")
      end

      test "enabled returns only registered, enabled keys in settings order" do
        Sources.stubs(:registry).returns({"alpha" => AlphaSource, "beta" => BetaSource, "gamma" => AlphaSource})
        Rails.application.config.x.publisher_intake.enabled_sources = %w[beta alpha]

        assert_equal [BetaSource, AlphaSource], Sources.enabled.map(&:class)
      end

      test "an unknown enabled key is skipped and logged" do
        Sources.stubs(:registry).returns({"alpha" => AlphaSource})
        Rails.application.config.x.publisher_intake.enabled_sources = %w[typo alpha]
        Rails.logger.expects(:warn).with(regexp_matches(/"typo"/)).once

        assert_equal [AlphaSource], Sources.enabled.map(&:class)
      end
    end
  end
end
