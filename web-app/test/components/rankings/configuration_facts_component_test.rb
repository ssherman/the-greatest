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

    test "renders the exponent and bonus pool, each in its own row" do
      @configuration.update!(exponent: 3.0, bonus_pool_percentage: 4.0)

      render_inline(ConfigurationFactsComponent.new(configurations: [@configuration]))

      exponent_row = page.find("tr", text: "Position bonus curve")
      assert_text(exponent_row, "3.0")

      bonus_pool_row = page.find("tr", text: "Bonus pool")
      assert_text(bonus_pool_row, "4.0")
    end

    test "reports the weight floor as zero rather than the stored minimum" do
      @configuration.update!(min_list_weight: -50)

      render_inline(ConfigurationFactsComponent.new(configurations: [@configuration]))

      assert_no_text "-50"
    end
  end
end
