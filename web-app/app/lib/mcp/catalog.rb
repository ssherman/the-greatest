# frozen_string_literal: true

module Mcp
  # The tool catalogue, generated from the hand-maintained OpenAPI document
  # (spec D5, D6, D9): one tool per operation that carries an `x-mcp` block, so
  # the document stays the one contract and an operation without the block (the
  # document's own endpoint, say) is simply not a tool.
  #
  # An operation's parameters and `application/json` body properties are
  # flattened into one strict object schema, with every `$ref` resolved inline:
  # the gem accepts same-document refs only, and an agent reads one flat schema
  # better than a tree of references. Generation fails loudly (GenerationError)
  # on anything it cannot represent faithfully, because a silently shadowed
  # argument or a tool with no scope is worse than a boot error.
  #
  # Each tool's call runs the real API controller through Mcp::Dispatcher. The
  # server context is the Hash `{principal:, request:}` the endpoint builds per
  # request.
  class Catalog
    class GenerationError < StandardError; end

    EXTENSION = "x-mcp"
    # REST says `per_page`; the tool says `limit` (anti-goal: REST paging names
    # do not leak). The wire name is kept on the Argument.
    RENAMES = {"per_page" => "limit"}.freeze
    LOCATIONS = %w[path query].freeze
    JSON_CONTENT = "application/json"

    # Idempotence follows the HTTP method; destructiveness is declared per
    # operation. Every hint is set explicitly because the gem defaults
    # destructive_hint (and open_world_hint) to true.
    IDEMPOTENT_METHODS = %w[get put delete].freeze

    # The catalogue for one document on one site. Memoised outside development,
    # like Api::OpenapiDocument.raw: the document changes only with a deploy.
    def self.for(document:, domain:)
      return build(document, domain) if Rails.env.development?

      (@catalogs ||= {})[[document, domain]] ||= build(document, domain)
    end

    def self.build(document, domain)
      new(::Api::OpenapiDocument.for_host(::Api::Host.base_url(domain), domain: domain, document: document))
    end
    private_class_method :build

    # `source` is a document Hash (`paths` and `components`).
    def initialize(source)
      @components = source["components"] || {}
      @operations = {}
      @tools = {}
      ::Api::OpenapiDocument.operations(source).each do |api_operation|
        next unless api_operation.definition.key?(EXTENSION)

        operation = generate(api_operation)
        raise GenerationError, "#{operation.operation_id}: tool name #{operation.tool_name.inspect} is already taken" if @tools.values.any? { |tool| tool.name_value == operation.tool_name }
        raise GenerationError, "operationId #{operation.operation_id.inspect} appears twice" if @operations.key?(operation.operation_id)

        @operations[operation.operation_id] = operation
        @tools[operation.operation_id] = build_tool(operation)
      end
      @operations.freeze
      @tools.freeze
    end

    def operations = @operations.values

    def fetch(operation_id) = @operations.fetch(operation_id)

    def tool(operation_id) = @tools.fetch(operation_id)

    # The tools whose operation scope the principal satisfies. The dispatched
    # controller still enforces its scope and policies on every call (D8).
    def tools_for(principal)
      @operations.filter_map { |operation_id, operation| @tools.fetch(operation_id) if principal.scope?(operation.scope) }
    end

    private

    def generate(api_operation)
      definition = api_operation.definition
      id = api_operation.operation_id
      extension = definition[EXTENSION] || {}
      description = extension["description"].to_s.strip
      raise GenerationError, "#{id}: x-mcp.description is required" if description.empty?

      title = definition["summary"].to_s.strip
      raise GenerationError, "#{id}: a summary is required (it is the tool's title)" if title.empty?

      scope = scope_of(api_operation)
      properties, required, arguments = flatten(api_operation)

      Mcp::Operation.new(
        operation_id: id,
        tool_name: extension["name"].presence || id.underscore,
        title: title,
        description: description,
        http_method: api_operation.http_method,
        path: api_operation.path,
        scope: scope,
        destructive: extension["destructive"] == true,
        arguments: arguments,
        input_schema: input_schema(properties, required)
      )
    end

    # A tool without a scope would be listed to everyone: fail closed.
    def scope_of(api_operation)
      scope = api_operation.scope
      raise GenerationError, "#{api_operation.operation_id}: an x-mcp operation must declare a scope" if scope.nil?

      scope
    rescue ArgumentError, KeyError => error
      raise GenerationError, "#{api_operation.operation_id}: #{error.message}"
    end

    def input_schema(properties, required)
      schema = {"type" => "object", "properties" => properties, "additionalProperties" => false}
      schema["required"] = required if required.any?
      schema
    end

    # Returns [properties, required, arguments], all keyed by tool argument name.
    def flatten(api_operation)
      id = api_operation.operation_id
      properties = {}
      required = []
      arguments = {}
      seen_at = {}

      add = lambda do |name, schema, location, wire_name, is_required|
        if seen_at.key?(name)
          raise GenerationError, "#{id}: argument #{name.inspect} is declared in both #{seen_at[name]} and #{location}"
        end

        seen_at[name] = location
        properties[name] = schema
        required << name if is_required
        arguments[name] = Mcp::Operation::Argument.new(location: location, wire_name: wire_name)
      end

      parameters(api_operation).each do |parameter|
        wire_name = parameter.fetch("name")
        schema = resolve(parameter["schema"] || {}, id)
        schema = schema.merge("description" => parameter["description"]) if parameter["description"]
        location = parameter.fetch("in").to_sym
        is_required = location == :path || parameter["required"] == true
        add.call(RENAMES.fetch(wire_name, wire_name), schema, location, wire_name, is_required)
      end

      body_schema(api_operation)&.then do |body|
        body_required = Array(body["required"])
        body.fetch("properties").each do |name, schema|
          add.call(name, schema, :body, name, body_required.include?(name))
        end
      end

      [properties, required, arguments]
    end

    # Path-item parameters, then the operation's own; an operation parameter
    # replaces a path-item one with the same name and location.
    def parameters(api_operation)
      id = api_operation.operation_id
      declared = Array(api_operation.path_item["parameters"]) + Array(api_operation.definition["parameters"])
      declared.map { |parameter| resolve(parameter, id) }
        .each_with_object({}) do |parameter, by_key|
          unless LOCATIONS.include?(parameter["in"])
            raise GenerationError, "#{id}: parameter #{parameter["name"].inspect} is in #{parameter["in"].inspect}, which a tool cannot take"
          end

          by_key[[parameter["name"], parameter["in"]]] = parameter
        end.values
    end

    def body_schema(api_operation)
      id = api_operation.operation_id
      request_body = api_operation.definition["requestBody"]
      return nil unless request_body

      content = resolve(request_body, id).dig("content", JSON_CONTENT)
      raise GenerationError, "#{id}: the request body must offer #{JSON_CONTENT}" unless content

      schema = resolve(content["schema"] || {}, id)
      raise GenerationError, "#{id}: the request body must be an object with properties" unless schema["properties"].is_a?(Hash)

      schema
    end

    # `node` with every `$ref` replaced by its target, recursively. Siblings of
    # a `$ref` are kept and win over the target's keys.
    def resolve(node, operation_id, seen = [])
      case node
      when Hash
        if node.key?("$ref")
          target = lookup(node["$ref"], operation_id)
          raise GenerationError, "#{operation_id}: #{node["$ref"]} refers to itself" if seen.include?(node["$ref"])

          resolve(target, operation_id, seen + [node["$ref"]]).merge(resolve(node.except("$ref"), operation_id, seen))
        else
          node.transform_values { |value| resolve(value, operation_id, seen) }
        end
      when Array
        node.map { |value| resolve(value, operation_id, seen) }
      else
        node
      end
    end

    def lookup(ref, operation_id)
      match = ref.to_s.match(%r{\A#/components/(\w+)/([^/]+)\z})
      target = match && @components.dig(match[1], match[2])
      raise GenerationError, "#{operation_id}: #{ref.inspect} does not resolve to a component" unless target

      target
    end

    def build_tool(operation)
      annotations = annotations_for(operation)
      ::MCP::Tool.define(
        name: operation.tool_name,
        title: operation.title,
        description: operation.description,
        input_schema: operation.input_schema,
        annotations: annotations
      ) do |server_context:, **arguments|
        ::Mcp::ToolResult.from(
          ::Mcp::Dispatcher.call(operation, arguments, principal: server_context[:principal], request: server_context[:request])
        )
      end
    end

    def annotations_for(operation)
      read_only = operation.http_method == "get"
      {
        read_only_hint: read_only,
        idempotent_hint: IDEMPOTENT_METHODS.include?(operation.http_method),
        destructive_hint: !read_only && operation.destructive,
        open_world_hint: false,
        title: operation.title
      }
    end
  end
end
