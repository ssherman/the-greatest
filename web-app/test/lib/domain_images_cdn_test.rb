require "test_helper"

# Guards the images_cdn hosts in config/initializers/domain_config.rb.
#
# These are plain config, but a wrong value here is invisible in every test and
# in admin (which proxies variants through Rails) and only shows up as broken
# images on public pages in the target environment.
class DomainImagesCdnTest < ActiveSupport::TestCase
  SETTINGS = Rails.application.config.domain_settings

  test "every domain defines a production and default images cdn" do
    SETTINGS.each do |domain, settings|
      cdn = settings[:images_cdn]

      assert cdn, "#{domain} has no images_cdn"
      assert cdn[:production].start_with?("https://"), "#{domain} production cdn is not https"
      assert cdn[:default].start_with?("https://"), "#{domain} default cdn is not https"
    end
  end

  test "production and default cdn hosts differ so dev never writes through a production host" do
    SETTINGS.each do |domain, settings|
      cdn = settings[:images_cdn]

      refute_equal cdn[:production], cdn[:default], "#{domain} uses the same cdn host in both environments"
    end
  end

  # The legacy thegreatestbooks.org site owns images.thegreatestbooks.org and binds
  # it to its own R2 bucket (the-greatest-books). This app's blobs live in a
  # different bucket, so pointing at that host serves 404s for every cover while
  # admin still looks fine. Only safe to use once the legacy site is retired.
  test "books does not serve images from the legacy site's cdn host" do
    cdn = SETTINGS[:books][:images_cdn]

    refute_includes cdn.values, "https://images.thegreatestbooks.org"
  end
end
