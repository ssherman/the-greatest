# frozen_string_literal: true

require "test_helper"

class Authentication::WidgetComponentTest < ViewComponent::TestCase
  def test_component_renders_without_errors
    # Should render without throwing any errors
    assert_nothing_raised do
      render_inline(Authentication::WidgetComponent.new)
    end
  end

  def test_component_renders_something
    # Should render some content
    result = render_inline(Authentication::WidgetComponent.new)
    assert_not_empty result.text.strip
  end

  def test_component_renders_html
    # Should render valid HTML
    result = render_inline(Authentication::WidgetComponent.new)
    assert_includes result.to_html, "<"
    assert_includes result.to_html, ">"
  end
end
