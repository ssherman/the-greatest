require "test_helper"

class PublicListsControllerTest < ActiveSupport::TestCase
  test "the base class refuses to run without a lists query class" do
    assert_raises(NotImplementedError) { PublicListsController.lists_query_class }
  end

  test "the base class refuses to run without a ranking configuration class" do
    assert_raises(NotImplementedError) { PublicListsController.ranking_configuration_class }
  end
end
