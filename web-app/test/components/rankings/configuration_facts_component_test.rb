require "test_helper"

module Rankings
  class ConfigurationFactsComponentTest < ViewComponent::TestCase
    setup do
      @configuration = ranking_configurations(:books_global)
    end

    test "renders the configuration name" do
      render_inline(ConfigurationFactsComponent.new(configurations: [@configuration]))

      assert_text @configuration.name
    end

    test "renders the exponent and bonus pool" do
      render_inline(ConfigurationFactsComponent.new(configurations: [@configuration]))

      assert_text @configuration.exponent.to_f.to_s
    end

    test "reports the weight floor as zero rather than the stored minimum" do
      @configuration.update!(min_list_weight: -50)

      render_inline(ConfigurationFactsComponent.new(configurations: [@configuration]))

      assert_no_text "-50"
    end
  end
end
