# frozen_string_literal: true

# Loads the hand-written contract and tailors it to the host it is being served
# from: `servers` becomes that host, and path items tagged `x-domain` are kept
# only on their own site. A client generated from the music host's document
# therefore never sees /api/v1/books, which is routed on the books host alone;
# untagged paths (this document itself) appear everywhere. Memoised outside
# development: the file changes only with a deploy.
#
# Two documents: the public one, and the admin one (served only to a token
# holding books:admin:read). The public document never mentions an admin path.
module Api
  module OpenapiDocument
    PATHS = {
      public: Rails.root.join("config/api/v1/openapi.yaml"),
      admin: Rails.root.join("config/api/v1/admin_openapi.yaml")
    }.freeze
    DOMAIN_KEY = "x-domain"
    HTTP_METHODS = %w[get put post delete patch].freeze

    # One operation of a document. `scope` is the single scope its `security`
    # declares (`[{bearerAuth: [scope]}]`), or nil for `security: []`, which is
    # how an operation that needs no token says so. Anything more elaborate (several
    # requirement objects, several scopes) raises instead of being guessed at: a
    # consumer filtering operations by scope would otherwise expose or hide them
    # on a guess.
    Operation = Struct.new(:http_method, :path, :operation_id, :path_item, :definition, keyword_init: true) do
      def scope
        requirements = definition.fetch("security")
        return nil if requirements.empty?

        raise ArgumentError, "#{operation_id} declares #{requirements.size} security requirements; expected one" unless requirements.one?

        scopes = requirements.first.values.flatten
        raise ArgumentError, "#{operation_id} declares #{scopes.size} scopes; expected one" unless scopes.one?

        scopes.first
      end
    end

    # Every operation in `source` (a document Hash: `raw` or `for_host` output),
    # in document order. Path-item keys that are not HTTP methods (`parameters`,
    # `x-domain`, `summary`, ...) are skipped.
    def self.operations(source)
      source.fetch("paths").flat_map do |path, item|
        item.slice(*HTTP_METHODS).map do |http_method, definition|
          Operation.new(http_method: http_method, path: path, operation_id: definition["operationId"],
            path_item: item, definition: definition)
        end
      end
    end

    def self.raw(document = :public)
      return load(document) if Rails.env.development?

      (@raw ||= {})[document] ||= load(document)
    end

    def self.for_host(base_url, domain:, document: :public)
      source = raw(document)
      paths = source.fetch("paths").select do |_path, item|
        item[DOMAIN_KEY].nil? || item[DOMAIN_KEY] == domain.to_s
      end

      source.merge("servers" => [{"url" => base_url}], "paths" => paths)
    end

    def self.load(document) = YAML.safe_load_file(PATHS.fetch(document), aliases: true)
  end
end
