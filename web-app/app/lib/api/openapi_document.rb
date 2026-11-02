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
