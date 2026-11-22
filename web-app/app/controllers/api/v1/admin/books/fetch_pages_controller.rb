# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # POST /api/v1/admin/fetch_page -- body {url, format?}
        #
        # Fetches one public page through the page fetcher and returns it as simplified HTML, text or
        # raw HTML (Services::PageContent). No domain data is read or written, so it sits under
        # Admin::Books only because every admin endpoint does; it needs the admin read scope. It is a
        # POST because it does work outside our servers.
        #
        # Fetcher failures: the fetcher refusing the address is a 422; the fetcher answering but not
        # getting the page is a 502; the fetcher being unreachable or unhealthy is a 503. None of them is
        # a 500. One log line per call, requests rejected before the fetch included, names the host and
        # never the full URL. A call can take up to about a minute (the client's budget plus its read padding).
        class FetchPagesController < BaseController
          include ::Api::JsonBody

          FETCH_TIMEOUT_MS = 45_000
          ALLOWED = %w[url format].freeze
          # ServerError codes that describe the site or the browser's attempt, not the service being down.
          PAGE_FAILURE_CODES = %w[browser_error navigation_timeout].freeze

          def create
            body = json_body
            return reject_bad("The body must be a JSON object.") if body.nil?

            unknown = body.keys - ALLOWED
            if unknown.any?
              log("-", "-", "rejected", 422)
              return unknown_fields(unknown, ALLOWED)
            end

            url = body["url"]
            return reject_bad("url is required and must be a string") unless url.is_a?(String) && url.strip.present?

            format = body.fetch("format", "simplified")
            unless ::Services::PageContent::FORMATS.include?(format)
              return reject_unprocessable("format must be one of #{::Services::PageContent::FORMATS.join(", ")}")
            end

            host = http_host(url.strip) or return reject_unprocessable("url must be an absolute http or https URL")

            page = fetch(url.strip, host, format) or return
            content = ::Services::PageContent.call(html: page.html, format: format).data
            log(host, format, "ok", page.status)
            render json: {data: {url: page.url, final_url: page.final_url, status: page.status, title: page.title,
                                 format: format, content: content[:content], length: content[:length],
                                 truncated: content[:truncated]}}
          end

          private

          # The URL's host when it is an absolute http(s) URL with one; nil otherwise. The parse is
          # lenient on purpose (accented paths, spaces and brackets are an agent's everyday URLs); the
          # URL goes to the fetcher exactly as sent, and whether the address is public is its check.
          def http_host(url)
            uri = Addressable::URI.parse(url)
            uri.host.presence if %w[http https].include?(uri.scheme&.downcase)
          rescue Addressable::URI::InvalidURIError
            nil
          end

          def reject_bad(detail)
            log("-", "-", "rejected", 400)
            bad_body(detail)
          end

          def reject_unprocessable(detail)
            log("-", "-", "rejected", 422)
            unprocessable(detail)
          end

          # The Page, or nil after rendering the problem.
          def fetch(url, host, format)
            PageFetcher::Client.new.fetch(url, timeout_ms: FETCH_TIMEOUT_MS)
          rescue PageFetcher::Exceptions::ClientError => e
            log(host, format, "refused", e.status_code)
            unprocessable("The page fetcher refused the URL: #{e.message}")
          rescue PageFetcher::Exceptions::UpstreamError => e
            page_failed(host, format, e)
          rescue PageFetcher::Exceptions::ServerError => e
            return page_failed(host, format, e) if PAGE_FAILURE_CODES.include?(e.error_code)

            unavailable(host, format, e)
          rescue PageFetcher::Exceptions::Error => e
            unavailable(host, format, e)
          end

          def page_failed(host, format, error)
            log(host, format, "page_failed", error.status_code)
            render_problem(::Api::Problem.new(:bad_gateway, detail: "The page fetcher could not get the page: #{error.message}"))
            nil
          end

          def unavailable(host, format, error)
            log(host, format, "fetcher_unavailable", error.class.name.demodulize)
            render_problem(::Api::Problem.new(:service_unavailable, detail: "The page fetcher is unavailable (#{error.class.name.demodulize}). Retry shortly."))
            nil
          end

          def unprocessable(detail)
            render_problem(::Api::Problem.new(:unprocessable, detail: detail))
            nil
          end

          def log(host, format, outcome, status)
            Rails.logger.info("event=api_admin_fetch_page token_id=#{current_principal.token.id} " \
              "user_id=#{current_principal.user.id} host=#{host} format=#{format} outcome=#{outcome} status=#{status}")
          end
        end
      end
    end
  end
end
