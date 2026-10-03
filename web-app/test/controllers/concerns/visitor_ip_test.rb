require "test_helper"

# visitor_ip is request.remote_ip, so what these pin is how Rails' RemoteIp
# middleware, with this app's own ip_spoofing_check and trusted_proxies,
# resolves the headers production actually delivers. REMOTE_ADDR is nginx's
# container on the Docker bridge. X-Forwarded-For is whatever arrived at nginx
# (anything the client sent, then the visitor Cloudflare appends) with nginx's
# $remote_addr -- the real_ip visitor -- appended last.
class VisitorIpTest < ActiveSupport::TestCase
  class Host
    include VisitorIp

    attr_reader :request

    def initialize(request) = @request = request

    public :visitor_ip
  end

  NGINX = "172.18.0.5"

  def visitor_ip_for(env)
    config = Rails.application.config.action_dispatch
    resolved = nil
    app = ->(rack_env) {
      resolved = Host.new(ActionDispatch::Request.new(rack_env)).visitor_ip
      [200, {}, []]
    }
    ActionDispatch::RemoteIp.new(app, config.ip_spoofing_check, config.trusted_proxies)
      .call(Rack::MockRequest.env_for("/", env))
    resolved
  end

  test "is the visitor nginx appended to X-Forwarded-For" do
    assert_equal "203.0.113.5",
      visitor_ip_for("REMOTE_ADDR" => NGINX, "HTTP_X_FORWARDED_FOR" => "203.0.113.5, 203.0.113.5")
  end

  test "ignores entries a client forged to the left of the visitor" do
    assert_equal "203.0.113.5",
      visitor_ip_for("REMOTE_ADDR" => NGINX, "HTTP_X_FORWARDED_FOR" => "198.51.100.66, 203.0.113.5, 203.0.113.5")
  end

  test "ignores a CF-Connecting-IP header" do
    assert_equal "203.0.113.5",
      visitor_ip_for("REMOTE_ADDR" => NGINX, "HTTP_X_FORWARDED_FOR" => "203.0.113.5, 203.0.113.5",
        "HTTP_CF_CONNECTING_IP" => "198.51.100.77")
  end

  test "handles an IPv6 visitor" do
    assert_equal "2001:db8::5",
      visitor_ip_for("REMOTE_ADDR" => NGINX, "HTTP_X_FORWARDED_FOR" => "2001:db8::5, 2001:db8::5")
  end

  test "is the peer itself when nothing forwarded the request" do
    assert_equal "127.0.0.1", visitor_ip_for("REMOTE_ADDR" => "127.0.0.1")
  end
end
