module Services
  module Books
    module Profiles
      # The edge-cached public URL of a reader profile, one per configured
      # Books host (hosts are split exactly like the router splits them).
      class CachedUrls
        def self.call(profile:)
          new(profile: profile).call
        end

        def initialize(profile:)
          @profile = profile
        end

        def call
          hosts.map { |host| "https://#{host}/profiles/#{profile.id}" }.uniq
        end

        private

        attr_reader :profile

        def hosts
          Rails.application.config.domains[:books]
            .to_s.split(",").reject(&:blank?)
        end
      end
    end
  end
end
