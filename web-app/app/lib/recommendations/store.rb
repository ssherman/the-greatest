# frozen_string_literal: true

require "aws-sdk-s3"

module Recommendations
  # Where exports and models live (spec 2 §2): a directory in development and
  # the harness, a private R2 bucket in production. Files are the interface;
  # the store only moves bytes and one-line pointers. Gzip is the caller's.
  module Store
    class Missing < StandardError; end

    class NotConfigured < StandardError; end

    # R2 when configured, never a silent local fallback: a production job
    # writing into the container's filesystem is the failure this prevents.
    def self.default
      R2.from_env or raise NotConfigured, "set #{R2::REQUIRED_KEYS.join(", ")} to use the recommendations store"
    end

    class Local
      attr_reader :dir

      def initialize(dir)
        @dir = Pathname.new(dir)
      end

      def put(key, data)
        path = @dir.join(key)
        path.dirname.mkpath
        File.binwrite(path, data)
      end

      def get(key)
        path = @dir.join(key)
        raise Missing, key unless path.file?

        File.binread(path)
      end

      def exist?(key)
        @dir.join(key).file?
      end

      def read_pointer(key)
        exist?(key) ? get(key).strip.presence : nil
      end

      def write_pointer(key, value)
        put(key, "#{value}\n")
      end
    end

    class R2
      REQUIRED_KEYS = %w[RECOMMENDATIONS_R2_ACCESS_KEY RECOMMENDATIONS_R2_SECRET_KEY RECOMMENDATIONS_R2_BUCKET].freeze
      # The S3 endpoint names the R2 account. Production already has STORAGE_ENDPOINT
      # for the same account (config/storage.yml's private_imports falls back to it
      # the same way); RECOMMENDATIONS_R2_ENDPOINT overrides it for a different account.
      ENDPOINT_KEYS = %w[RECOMMENDATIONS_R2_ENDPOINT STORAGE_ENDPOINT].freeze

      attr_reader :bucket, :client

      def self.from_env
        values = REQUIRED_KEYS.map { |k| ENV[k].presence }
        return nil if values.all?(&:nil?)
        raise NotConfigured, "#{REQUIRED_KEYS.join(", ")} must all be set or all be unset" if values.any?(&:nil?)

        endpoint = ENDPOINT_KEYS.filter_map { |k| ENV[k].presence }.first
        raise NotConfigured, "set #{ENDPOINT_KEYS.join(" or ")} for the recommendations store" if endpoint.nil?

        access, secret, bucket = values
        client = Aws::S3::Client.new(
          endpoint: endpoint,
          access_key_id: access, secret_access_key: secret,
          region: "auto", force_path_style: true,
          # Newer aws-sdk-s3 adds checksum headers to every upload, which R2 mishandles;
          # same setting as the writers in config/storage.yml.
          request_checksum_calculation: "when_required",
          response_checksum_validation: "when_required"
        )
        new(client: client, bucket: bucket)
      end

      def initialize(client:, bucket:)
        @client = client
        @bucket = bucket
      end

      def put(key, data)
        @client.put_object(bucket: @bucket, key: key, body: data)
      end

      def get(key)
        @client.get_object(bucket: @bucket, key: key).body.read
      rescue Aws::S3::Errors::NoSuchKey
        raise Missing, key
      end

      def exist?(key)
        @client.head_object(bucket: @bucket, key: key)
        true
      rescue Aws::S3::Errors::NotFound
        false
      end

      def read_pointer(key)
        get(key).strip.presence
      rescue Missing
        nil
      end

      def write_pointer(key, value)
        put(key, "#{value}\n")
      end
    end
  end
end
