# frozen_string_literal: true

module Mcp
  # A hand-written tool that answers one question with several API operations
  # (spec D13). It is an allowlist entry, not a second implementation: a
  # composite reaches data only through `dispatch`, which runs the real API
  # controller for an operation the composite declared, so authorization,
  # validation and errors are the API's own.
  #
  # A subclass declares the operations it uses with `operations`, gives the
  # tool's `tool_name`, `title`, `description` and `input_schema`, and
  # implements `run(catalog, args, principal:, request:)` returning an
  # MCP::Tool::Response. Its listing scope is the union of its operations'
  # scopes: it is offered only to a principal who could call every one.
  class Composite
    ANNOTATIONS = {read_only_hint: true, idempotent_hint: true, destructive_hint: false, open_world_hint: false}.freeze

    class << self
      # Declares the operations when given ids; reads them back with none.
      def operations(*operation_ids)
        @operation_ids = operation_ids.freeze if operation_ids.any?
        operation_ids_declared
      end

      def operation_ids = operation_ids_declared

      def visible_to?(principal, catalog)
        operation_ids.all? { |id| principal.scope?(catalog.fetch(id).scope) }
      end

      # The MCP tool for this catalogue, built once per catalogue. The cache
      # lives on the catalogue (Catalog#cached), so it lasts exactly as long as
      # the catalogue does, including when development rebuilds it per request.
      def tool(catalog)
        catalog.cached(self) { build_tool(catalog) }
      end

      def dispatch(catalog, operation_id, args, principal:, request:)
        raise ArgumentError, "#{name} did not declare #{operation_id}" unless operation_ids.include?(operation_id)

        ::Mcp::Dispatcher.call(catalog.fetch(operation_id), args, principal: principal, request: request)
      end

      def run(_catalog, _args, principal:, request:)
        raise NotImplementedError, "#{name} must implement run"
      end

      private

      def operation_ids_declared = @operation_ids || []

      def build_tool(catalog)
        composite = self
        ::MCP::Tool.define(
          name: tool_name,
          title: title,
          description: description,
          input_schema: input_schema,
          annotations: ANNOTATIONS.merge(title: title)
        ) do |server_context:, **arguments|
          composite.run(catalog, arguments, principal: server_context[:principal], request: server_context[:request])
        end
      end
    end
  end
end
