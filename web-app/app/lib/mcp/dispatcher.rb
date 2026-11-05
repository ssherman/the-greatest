# frozen_string_literal: true

module Mcp
  # Runs one tool call as the REST request it stands for, in this process, by
  # building a Rack env and handing it to the router. The real API controller
  # answers, so a tool and its REST twin cannot drift apart: the same
  # authorization, validation, serialization and errors.
  #
  # Calling Rails.application.routes.call skips the whole middleware stack, which
  # has two consequences this class pays for (spec D10):
  #
  # - Rails.application.env_config is merged into the env. It carries
  #   action_dispatch.parameter_filter; without it the inner "Parameters:" log
  #   line would print tokens and other filtered values in the clear.
  # - request.remote_ip comes from the RemoteIp middleware, which does not run
  #   here, so action_dispatch.remote_ip is copied from the outer request.
  #   `visitor_ip` (the key of the inner unauthenticated-visitor rate-limit
  #   window) reads exactly that, so it is the same window the outer request
  #   used. REMOTE_ADDR is copied as well, as defence in depth for anything that
  #   reads `request.ip` instead. action_dispatch.request_id is copied so the inner log lines and any
  #   problem body carry the outer request's id.
  #
  # A nil argument is omitted from the path and the query (an unset filter, not
  # a value), but sent as JSON null in the body: the admin API's PATCH uses null
  # to clear a field (parent_id, description), so dropping it would turn a clear
  # into a silent no-op 200. An unknown argument is rejected whether or not its
  # value is nil, and a nil path argument counts as missing.
  #
  # The skipped stack also includes ShowExceptions, so an exception in a
  # controller escapes routes.call. It is rescued here, reported, and turned into
  # a generic internal_error that never carries the exception's message.
  #
  # The outer /api/mcp POST authenticated and counted its rate-limit hit once.
  # The principal rides in the env under keys no client header can set
  # (Api::DispatchedRequest), so the inner request neither looks the token up
  # again nor counts a second hit. This class is the only caller of that mark.
  class Dispatcher
    Response = Struct.new(:status, :body, keyword_init: true)

    INTERNAL_ERROR_DETAIL = "The tool failed unexpectedly."

    def self.call(operation, arguments, principal:, request:)
      new(operation, arguments, principal, request).call
    end

    def initialize(operation, arguments, principal, request)
      @operation = operation
      @arguments = arguments.to_h.transform_keys(&:to_s)
      @principal = principal
      @request = request
    end

    def call
      unknown = @arguments.keys - @operation.arguments.keys
      return invalid_parameter("Unknown argument: #{unknown.sort.map { |name| with_rename_hint(name) }.join(", ")}") if unknown.any?

      # A blank path value would interpolate to an empty segment, and the router
      # collapses that ("/widgets/" is the index, "/widgets//parts" is "/widgets/parts"),
      # reaching a different operation. Blank means missing.
      missing = path_names.select { |name| @arguments[name].to_s.strip.empty? }
      return invalid_parameter("Missing argument: #{missing.sort.join(", ")}") if missing.any?

      dispatch
    end

    private

    # An agent that knows the REST API may send the wire name of an argument the
    # tool renamed (`per_page` for `limit`): say what to use instead.
    def with_rename_hint(name)
      renamed = @operation.arguments.find { |tool_name, argument| argument.wire_name == name && tool_name != name }&.first
      renamed ? "#{name} (use #{renamed})" : name
    end

    def dispatch
      env = build_env
      status, headers, body = keeping_execution_context { ::Rails.application.routes.call(env) }
      Response.new(status: status, body: parse(headers, read(body)))
    rescue => error
      ::Rails.error.report(error, handled: true, severity: :error, context: {operation_id: @operation.operation_id})
      Response.new(status: 500, body: {
        "code" => "internal_error",
        "detail" => INTERNAL_ERROR_DETAIL,
        "request_id" => @request.request_id
      }.compact)
    end

    # The inner controller records itself as the execution context's controller
    # and never restores it, so an error reported after the tool call would name
    # the inner controller instead of the outer one.
    def keeping_execution_context
      outer = ::ActiveSupport::ExecutionContext.to_h[:controller]
      yield
    ensure
      ::ActiveSupport::ExecutionContext[:controller] = outer
    end

    def build_env
      body = json_body
      options = {
        :method => @operation.http_method.upcase,
        "HTTP_ACCEPT" => "application/json",
        "HTTP_HOST" => @request.host_with_port,
        "HTTPS" => @request.ssl? ? "on" : "off",
        "REMOTE_ADDR" => @request.env["REMOTE_ADDR"]
      }.compact
      if body
        options[:input] = body
        options["CONTENT_TYPE"] = "application/json"
      end

      env = Rack::MockRequest.env_for(path_with_query, options)
      env["action_dispatch.remote_ip"] = @request.env["action_dispatch.remote_ip"]
      env["action_dispatch.request_id"] = @request.env["action_dispatch.request_id"]
      env.merge!(::Rails.application.env_config)
      ::Api::DispatchedRequest.mark(env, @principal)
    end

    def path_names
      @operation.arguments.select { |_, argument| argument.location == :path }.keys
    end

    # A slug can hold "/" or "." ("war.and", "a/b"). Unencoded, "/" routes to a
    # different operation and "." trips the format constraint, so both are
    # encoded; url_encode leaves "." alone, hence the extra step.
    def interpolated_path
      @operation.path.gsub(/\{(\w+)\}/) do
        value = @arguments[Regexp.last_match(1)]
        ERB::Util.url_encode(value.to_s).gsub(".", "%2E")
      end
    end

    def path_with_query
      query = Rack::Utils.build_nested_query(arguments_at(:query))
      query.empty? ? interpolated_path : "#{interpolated_path}?#{query}"
    end

    def json_body
      body = arguments_at(:body)
      body.empty? ? nil : JSON.generate(body)
    end

    # The arguments that go at `location`, under their wire names. A nil is
    # dropped everywhere except the body (see the class comment).
    def arguments_at(location)
      @arguments.each_with_object({}) do |(name, value), wire|
        argument = @operation.arguments.fetch(name)
        next unless argument.location == location
        next if value.nil? && location != :body

        wire[argument.wire_name] = value
      end
    end

    def read(rack_body)
      chunks = []
      rack_body.each { |chunk| chunks << chunk }
      chunks.join
    ensure
      rack_body.close if rack_body.respond_to?(:close)
    end

    def parse(headers, text)
      content_type = headers.find { |name, _| name.to_s.casecmp?("content-type") }&.last.to_s
      return nil unless content_type.match?(%r{\Aapplication/(problem\+)?json}) && text.present?

      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    def invalid_parameter(detail)
      Response.new(status: 400, body: {"code" => "invalid_parameter", "detail" => detail})
    end
  end
end
