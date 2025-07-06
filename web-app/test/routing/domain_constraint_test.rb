require "test_helper"

class DomainConstraintTest < ActionDispatch::IntegrationTest
  test "domain constraint should match correct host" do
    constraint = DomainConstraint.new("dev.thegreatestmusic.org")

    # Mock request with correct host
    request = ActionDispatch::TestRequest.create
    request.host = "dev.thegreatestmusic.org"

    assert constraint.matches?(request)
  end

  test "domain constraint should not match wrong host" do
    constraint = DomainConstraint.new("dev.thegreatestmusic.org")

    # Mock request with wrong host
    request = ActionDispatch::TestRequest.create
    request.host = "dev.thegreatestmovies.org"

    assert_not constraint.matches?(request)
  end

  test "domain constraint with multiple domains" do
    constraint = DomainConstraint.new("dev.thegreatestmusic.org,dev.thegreatestmovies.org")

    request1 = ActionDispatch::TestRequest.create
    request1.host = "dev.thegreatestmusic.org"
    assert constraint.matches?(request1)

    request2 = ActionDispatch::TestRequest.create
    request2.host = "dev.thegreatestmovies.org"
    assert constraint.matches?(request2)

    request3 = ActionDispatch::TestRequest.create
    request3.host = "dev.thegreatest.games"
    assert_not constraint.matches?(request3)
  end
end
