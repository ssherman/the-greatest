require "aws-sdk-s3"

module Services
  module BooksMigration
    # S3-API access to the OLD TheGreatestBooks Cloudflare R2 bucket, the source
    # of the legacy book cover originals. Credentials come from four LEGACY_R2_*
    # env vars (dev: web-app/.env; prod: encrypted secrets/.env.production). These
    # are transient — needed only by the one-time data_migration:book_images run.
    module LegacyR2
      def self.endpoint
        "https://#{ENV.fetch("LEGACY_R2_ACCOUNT_ID")}.r2.cloudflarestorage.com"
      end

      def self.bucket
        ENV.fetch("LEGACY_R2_BUCKET")
      end

      def self.client
        Aws::S3::Client.new(
          endpoint: endpoint,
          access_key_id: ENV.fetch("LEGACY_R2_ACCESS_KEY"),
          secret_access_key: ENV.fetch("LEGACY_R2_SECRET_KEY"),
          region: "auto",
          force_path_style: true
        )
      end
    end
  end
end
