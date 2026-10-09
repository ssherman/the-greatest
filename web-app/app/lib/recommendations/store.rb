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
      R2.from_env or raise NotConfigured, "set #{R2::ENV_KEYS.join(", ")} to use the recommendations store"
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
      ENV_KEYS = %w[RECOMMENDATIONS_R2_ACCOUNT_ID RECOMMENDATIONS_R2_ACCESS_KEY
        RECOMMENDATIONS_R2_SECRET_KEY RECOMMENDATIONS_R2_BUCKET].freeze

      attr_reader :bucket

      def self.from_env
        values = ENV_KEYS.map { |k| ENV[k].presence }
        return nil if values.all?(&:nil?)
        raise NotConfigured, "#{ENV_KEYS.join(", ")} must all be set or all be unset" if values.any?(&:nil?)

        account, access, secret, bucket = values
        client = Aws::S3::Client.new(
          endpoint: "https://#{account}.r2.cloudflarestorage.com",
          access_key_id: access, secret_access_key: secret,
          region: "auto", force_path_style: true
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
