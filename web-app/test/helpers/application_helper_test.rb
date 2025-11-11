require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "format_duration returns MM:SS format" do
    assert_equal "4:00", format_duration(240)
    assert_equal "1:30", format_duration(90)
    assert_equal "0:45", format_duration(45)
  end

  test "format_duration handles nil" do
    assert_equal "—", format_duration(nil)
  end

  test "format_duration handles zero" do
    assert_equal "—", format_duration(0)
  end

  test "format_duration handles hours (60+ minutes)" do
    assert_equal "1:00:00", format_duration(3600)
    assert_equal "1:30:15", format_duration(5415)
    assert_equal "2:15:30", format_duration(8130)
  end
end
