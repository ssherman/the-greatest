xml.instruct! :xml, version: "1.0"
xml.rss version: "2.0", "xmlns:atom": "http://www.w3.org/2005/Atom" do
  xml.channel do
    xml.title "#{domain_name} News"
    # news_url, not request.original_url: this must be the same URL the HTML
    # index canonicalises to, or a reader and a search engine disagree about
    # which page the feed belongs to.
    xml.link news_url
    xml.description "Site news, ranking updates and new features from #{domain_name}."
    xml.language "en"
    xml.tag!("atom:link", href: news_url(format: :rss), rel: "self", type: "application/rss+xml")

    @news_posts.each do |news_post|
      xml.item do
        xml.title news_post.title
        xml.link news_post_url(slug: news_post.slug)
        # guid is the stable identity a reader dedupes on. isPermaLink false
        # because the slug is frozen but the host differs between environments.
        xml.guid news_post_url(slug: news_post.slug), isPermaLink: "false"
        xml.pubDate news_post.published_at.rfc822
        xml.description do
          # cdata! is safe without escaping the terminator: BodyRenderer emits
          # "&gt;" for every ">" it renders, in body text, inline code and fenced
          # blocks alike, so its output cannot contain a literal "]]>".
          # Verified against all three positions rather than assumed.
          xml.cdata! Services::News::BodyRenderer.call(news_post.body)
        end
        news_post.news_topics.each { |topic| xml.category topic.name }
      end
    end
  end
end
