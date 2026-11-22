require "test_helper"

module Api
  module V1
    module Admin
      module Books
        # POST /api/v1/admin/fetch_page. The page fetcher is always stubbed.
        class FetchPagesControllerTest < ActionDispatch::IntegrationTest
          READ = ApiTokenSecrets::ADMIN_READ
          MEMBER = ApiTokenSecrets::MEMBER
          URL = "https://example.org/best-books"

          HTML = <<~HTML
            <html><head><title>Best</title><script>x()</script></head><body>
            <!-- BEGIN WAYBACK TOOLBAR INSERT --><div id="wm-ipp">toolbar</div><!-- END WAYBACK TOOLBAR INSERT -->
            <h2 class="t">Top</h2><ol><li>Ulysses</li></ol></body></html>
          HTML

          setup { host! "dev-new.thegreatestbooks.org" }

          def json = response.parsed_body.deep_symbolize_keys

          def page(html: HTML, status: 200)
            PageFetcher::Page.new(url: URL, final_url: "https://example.org/final", status: status, title: "Best",
              html: html, selector_found: nil, elapsed_ms: 10, fetched_at: Time.current)
          end

          def fetch_page(body, token: READ)
            post "/api/v1/admin/fetch_page", params: body.is_a?(String) ? body : body.to_json,
              headers: bearer(token).merge("CONTENT_TYPE" => "application/json")
          end

          test "returns simplified content by default" do
            PageFetcher::Client.any_instance.expects(:fetch).with(URL, timeout_ms: 45_000).returns(page)

            fetch_page({url: URL})
            assert_api_response_conform(status: 200, api: :admin)

            data = json[:data]
            assert_equal [URL, "https://example.org/final", 200, "Best", "simplified"],
              data.values_at(:url, :final_url, :status, :title, :format)
            assert_includes data[:content], "<ol>"
            assert_not_includes data[:content], "toolbar"
            assert_not_includes data[:content], "<script"
            assert_equal [false, data[:content].length], [data[:truncated], data[:length]]
          end

          test "returns text" do
            PageFetcher::Client.any_instance.stubs(:fetch).returns(page)

            fetch_page({url: URL, format: "text"})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal "text", json[:data][:format]
            assert_no_match(/<[a-z]/, json[:data][:content])
            assert_includes json[:data][:content], "Ulysses"
          end

          test "returns html" do
            PageFetcher::Client.any_instance.stubs(:fetch).returns(page)

            fetch_page({url: URL, format: "html"})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal "html", json[:data][:format]
            assert_includes json[:data][:content], 'class="t"'
            assert_not_includes json[:data][:content], "toolbar"
          end

          test "a long page is cut with truncated and the true length" do
            PageFetcher::Client.any_instance.stubs(:fetch).returns(page(html: "<p>#{"é" * 150_000}</p>"))

            fetch_page({url: URL, format: "text"})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [100_000, true, 150_000], [json[:data][:content].length, json[:data][:truncated], json[:data][:length]]
          end

          test "the site's own status is reported" do
            PageFetcher::Client.any_instance.stubs(:fetch).returns(page(status: 403))

            fetch_page({url: URL})

            assert_equal 403, json[:data][:status]
          end

          test "a missing, blank or non-string url is a 400 and never fetches" do
            PageFetcher::Client.any_instance.expects(:fetch).never

            [{}, {url: ""}, {url: "   "}, {url: 5}, {url: nil}].each do |body|
              fetch_page(body)
              assert_response 400, body.inspect
              assert_equal "invalid_parameter", json[:code]
            end
          end

          test "a body that is not a JSON object is a 400" do
            PageFetcher::Client.any_instance.expects(:fetch).never

            fetch_page("not json")

            assert_response 400
          end

          test "a non-http(s) or malformed url is a 422 and never fetches" do
            PageFetcher::Client.any_instance.expects(:fetch).never

            ["ftp://example.org/x", "javascript:alert(1)", "file:///etc/passwd", "not a url", "https://"].each do |url|
              fetch_page({url: url})
              assert_response 422, url
              assert_equal "unprocessable", json[:code]
            end
          end

          test "a url with accented characters, spaces or brackets is fetched as sent" do
            ["https://es.wikipedia.org/wiki/Año", "https://example.org/a b/x[1]", "HTTPS://Example.org/x"].each do |url|
              PageFetcher::Client.any_instance.expects(:fetch).with(url, timeout_ms: 45_000).returns(page)

              fetch_page({url: url})

              assert_response 200, url
            end
          end

          test "a request rejected before the fetch is logged without the url" do
            lines = []
            Rails.logger.stubs(:info).with { |message| lines << message.to_s }

            fetch_page({url: "ftp://example.org/secret"})
            fetch_page({})

            logged = lines.select { |message| message.include?("event=api_admin_fetch_page") }
            assert_equal 2, logged.size
            assert logged.all? { |line| line.include?("outcome=rejected") }
            assert logged.none? { |line| line.include?("secret") }
          end

          test "an unknown format is a 422 and never fetches" do
            PageFetcher::Client.any_instance.expects(:fetch).never

            fetch_page({url: URL, format: "pdf"})

            assert_response 422
            assert_match(/format/, json[:detail])
          end

          test "an unknown field is a 422" do
            PageFetcher::Client.any_instance.expects(:fetch).never

            fetch_page({url: URL, wait: 5})

            assert_response 422
          end

          test "the fetcher refusing the address is a 422" do
            PageFetcher::Client.any_instance.stubs(:fetch)
              .raises(PageFetcher::Exceptions::ClientError.new("invalid_url: private address", 400, nil, error_code: "invalid_url"))

            fetch_page({url: "http://10.0.0.1/"})
            assert_api_response_conform(status: 422, api: :admin)

            assert_equal "unprocessable", json[:code]
            assert_includes json[:detail], "invalid_url"
          end

          test "a page the fetcher could not get is a 502 carrying its code and message" do
            [
              PageFetcher::Exceptions::UpstreamError.new("upstream_unreachable: dns", 502, nil, error_code: "upstream_unreachable"),
              PageFetcher::Exceptions::UpstreamError.new("html_too_large", 502, nil, error_code: "html_too_large"),
              PageFetcher::Exceptions::ServerError.new("browser_error: boom", 502, nil, error_code: "browser_error"),
              PageFetcher::Exceptions::ServerError.new("navigation_timeout: slow", 504, nil, error_code: "navigation_timeout")
            ].each do |error|
              PageFetcher::Client.any_instance.stubs(:fetch).raises(error)

              fetch_page({url: URL})
              assert_api_response_conform(status: 502, api: :admin)

              assert_equal "bad_gateway", json[:code], error.message
              assert_includes json[:detail], error.message
            end
          end

          test "a fetcher that is unavailable is a 503" do
            [
              PageFetcher::Exceptions::CircuitOpenError.new("open"),
              PageFetcher::Exceptions::TimeoutError.new("slow"),
              PageFetcher::Exceptions::NetworkError.new("down"),
              PageFetcher::Exceptions::ParseError.new("garbled"),
              PageFetcher::Exceptions::ConfigurationError.new("no url"),
              PageFetcher::Exceptions::ServerError.new("browser_unavailable", 503, nil, error_code: "browser_unavailable"),
              PageFetcher::Exceptions::HttpError.new("Unexpected status: 302", 302)
            ].each do |error|
              PageFetcher::Client.any_instance.stubs(:fetch).raises(error)

              fetch_page({url: URL})
              assert_api_response_conform(status: 503, api: :admin)

              assert_equal "service_unavailable", json[:code], error.class.name
            end
          end

          test "a member token is a 403 and a missing token a 401" do
            PageFetcher::Client.any_instance.expects(:fetch).never

            fetch_page({url: URL}, token: MEMBER)
            assert_response 403

            post "/api/v1/admin/fetch_page", params: {url: URL}.to_json, headers: {"CONTENT_TYPE" => "application/json"}
            assert_response 401
          end

          test "the read-scoped admin token is allowed" do
            PageFetcher::Client.any_instance.stubs(:fetch).returns(page)

            fetch_page({url: URL}, token: READ)

            assert_response 200
          end

          test "the log line has the host and no full URL" do
            PageFetcher::Client.any_instance.stubs(:fetch).returns(page)
            lines = []
            Rails.logger.stubs(:info).with { |message| lines << message.to_s }

            fetch_page({url: "https://example.org/secret/path?token=abc"})

            line = lines.find { |message| message.include?("event=api_admin_fetch_page") }
            assert line, "no fetch_page log line"
            assert_includes line, "host=example.org"
            assert_includes line, "format=simplified"
            assert_includes line, "outcome=ok"
            assert_not_includes line, "secret"
            assert_not_includes line, "token=abc"
          end
        end
      end
    end
  end
end
