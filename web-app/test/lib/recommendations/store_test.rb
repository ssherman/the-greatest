# frozen_string_literal: true

require "test_helper"
require "aws-sdk-s3"

module Recommendations
  class StoreTest < ActiveSupport::TestCase
    def with_env(values)
      old = values.keys.to_h { |k| [k, ENV[k]] }
      values.each { |k, v| ENV[k] = v }
      yield
    ensure
      old.each { |k, v| ENV[k] = v }
    end

    test "local store round-trips binary data, pointers and existence" do
      Dir.mktmpdir do |dir|
        store = Store::Local.new(dir)
        assert_not store.exist?("recommendations/books/model/x.csv.gz")
        assert_nil store.read_pointer("recommendations/books/model/latest")

        store.put("recommendations/books/model/x.csv.gz", "\x1f\x8b\x00binary".b)
        assert store.exist?("recommendations/books/model/x.csv.gz")
        assert_equal "\x1f\x8b\x00binary".b, store.get("recommendations/books/model/x.csv.gz")

        store.write_pointer("recommendations/books/model/latest", "x")
        assert_equal "x", store.read_pointer("recommendations/books/model/latest")
        assert_equal "x\n", File.read(File.join(dir, "recommendations/books/model/latest"))
      end
    end

    test "local store raises Missing for an absent key" do
      Dir.mktmpdir do |dir|
        assert_raises(Store::Missing) { Store::Local.new(dir).get("nope") }
      end
    end

    test "r2 store uses the bucket and keys verbatim" do
      client = Aws::S3::Client.new(stub_responses: true, region: "auto")
      store = Store::R2.new(client: client, bucket: "tg-recs")

      client.stub_responses(:get_object, {body: "payload"})
      assert_equal "payload", store.get("recommendations/books/model/latest")
      assert_equal "tg-recs", client.api_requests.last[:params][:bucket]
      assert_equal "recommendations/books/model/latest", client.api_requests.last[:params][:key]

      store.put("k", "v")
      assert_equal "v", client.api_requests.last[:params][:body]

      client.stub_responses(:head_object, "NotFound")
      assert_not store.exist?("k")
      client.stub_responses(:get_object, "NoSuchKey")
      assert_raises(Store::Missing) { store.get("k") }
      assert_nil store.read_pointer("k")
    end

    test "default is R2 when the four variables are set and raises otherwise" do
      with_env("RECOMMENDATIONS_R2_ACCOUNT_ID" => nil, "RECOMMENDATIONS_R2_ACCESS_KEY" => nil,
        "RECOMMENDATIONS_R2_SECRET_KEY" => nil, "RECOMMENDATIONS_R2_BUCKET" => nil) do
        assert_nil Store::R2.from_env
        assert_raises(Store::NotConfigured) { Store.default }
      end
      with_env("RECOMMENDATIONS_R2_ACCOUNT_ID" => "acct", "RECOMMENDATIONS_R2_ACCESS_KEY" => "a",
        "RECOMMENDATIONS_R2_SECRET_KEY" => "s", "RECOMMENDATIONS_R2_BUCKET" => "b") do
        store = Store.default
        assert_kind_of Store::R2, store
        assert_equal "b", store.bucket
      end
      with_env("RECOMMENDATIONS_R2_ACCOUNT_ID" => "acct", "RECOMMENDATIONS_R2_ACCESS_KEY" => nil,
        "RECOMMENDATIONS_R2_SECRET_KEY" => "s", "RECOMMENDATIONS_R2_BUCKET" => "b") do
        assert_raises(Store::NotConfigured) { Store.default }
      end
    end
  end
end
