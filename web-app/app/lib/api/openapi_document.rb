# frozen_string_literal: true

# Loads the hand-written contract and tailors it to the host it is being served
# from: `servers` becomes that host, and path items tagged `x-domain` are kept
# only on their own site. A client generated from the music host's document
# therefore never sees /api/v1/books, which is routed on the books host alone;
# untagged paths (this document itself) appear everywhere. Memoised outside
# development: the file changes only with a deploy.
module Api
  module OpenapiDocument
    PATH = Rails.root.join("config/api/v1/openapi.yaml")
    DOMAIN_KEY = "x-domain"

    def self.raw
      return load if Rails.env.development?

      @raw ||= load
    end

    def self.for_host(base_url, domain:)
      paths = raw.fetch("paths").select do |_path, item|
        item[DOMAIN_KEY].nil? || item[DOMAIN_KEY] == domain.to_s
      end

      raw.merge("servers" => [{"url" => base_url}], "paths" => paths)
    end

    def self.load = YAML.safe_load_file(PATH, aliases: true)
  end
end
