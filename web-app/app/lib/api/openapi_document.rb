# frozen_string_literal: true

# Loads the hand-written contract and stamps the host it is being served from
# into `servers`, so a client that fetches it from the music site gets music
# URLs. Memoised outside development: the file changes only with a deploy.
module Api
  module OpenapiDocument
    PATH = Rails.root.join("config/api/v1/openapi.yaml")

    def self.raw
      return load if Rails.env.development?

      @raw ||= load
    end

    def self.for_host(base_url)
      raw.merge("servers" => [{"url" => base_url}])
    end

    def self.load = YAML.safe_load_file(PATH, aliases: true)
  end
end
