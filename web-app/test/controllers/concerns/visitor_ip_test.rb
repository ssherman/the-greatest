require "test_helper"

class VisitorIpTest < ActiveSupport::TestCase
  class Host
    include VisitorIp

    attr_accessor :request

    def initialize(request) = @request = request

    public :visitor_ip
  end

  FakeRequest = Struct.new(:headers, :remote_ip)

  test "prefers the Cloudflare connecting IP" do
    host = Host.new(FakeRequest.new({"CF-Connecting-IP" => "198.51.100.4"}, "172.16.0.1"))
    assert_equal "198.51.100.4", host.visitor_ip
  end

  test "falls back to remote_ip when the header is absent" do
    host = Host.new(FakeRequest.new({}, "172.16.0.1"))
    assert_equal "172.16.0.1", host.visitor_ip
  end

  test "falls back to remote_ip when the header is blank" do
    host = Host.new(FakeRequest.new({"CF-Connecting-IP" => ""}, "172.16.0.1"))
    assert_equal "172.16.0.1", host.visitor_ip
  end
end
