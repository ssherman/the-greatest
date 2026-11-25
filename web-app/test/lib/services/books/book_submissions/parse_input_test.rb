require "test_helper"

module Services
  module Books
    module BookSubmissions
      class ParseInputTest < ActiveSupport::TestCase
        GOODREADS = {
          "https://www.goodreads.com/book/show/13651" => 13651,
          "https://www.goodreads.com/book/show/13651-the-dispossessed?ref=x" => 13651,
          "http://goodreads.com/en/book/show/13651.The_Dispossessed" => 13651,
          "www.goodreads.com/book/show/13651" => 13651,
          "HTTPS://WWW.Goodreads.com:443/book/show/13651" => 13651
        }
        AMAZON = {
          "https://www.amazon.com/Dispossessed/dp/0061054887/ref=sr_1_1" => ["0061054887", "0061054887"],
          "https://www.amazon.co.uk/gp/product/B000FC11JE" => ["B000FC11JE", nil],
          "https://www.amazon.de/gp/aw/d/0061054887" => ["0061054887", "0061054887"]
        }
        REFUSED = [
          ["goodreads", "https://www.goodreads.com/author/show/874602"],
          ["goodreads", "https://evilgoodreads.com/book/show/1"],
          ["goodreads", "https://www.amazon.com/dp/0061054887"],
          ["amazon", "https://a.co/d/abc"],
          ["amazon", "https://amazon.com.evil.test/dp/0061054887"],
          ["isbn", "9780061054880"],
          ["isbn", "5012345678900"],
          ["goodreads", "javascript:alert(1)"],
          ["goodreads", "javascript:alert(1);'@www.goodreads.com/book/show/1-x'"],
          ["amazon", "javascript:alert(1);'@www.amazon.com/dp/0061054887/x'"],
          ["goodreads", "https://evil.test@www.goodreads.com/book/show/1"],
          ["goodreads", "https://@www.goodreads.com/book/show/1"],
          ["amazon", "https://@www.amazon.com/dp/0061054887"],
          ["goodreads", "javascript:1//www.goodreads.com/book/show/1"],
          ["goodreads", "javascript:alert(1)//www.goodreads.com/book/show/1"],
          ["amazon", "javascript:1/www.amazon.com/dp/0061054887"],
          ["goodreads", "user:pw@www.goodreads.com/book/show/1"],
          ["goodreads", "evil.test%40www.goodreads.com/book/show/1-x"],
          ["goodreads", "https://evil.test%40www.goodreads.com/book/show/1-x"],
          ["goodreads", "%40www.goodreads.com/book/show/1-x"],
          ["goodreads", "javascript%3Aalert(1)%40www.goodreads.com/book/show/1-x"],
          ["goodreads", "javascript%3Aalert(1);'.www.goodreads.com/book/show/1-x"],
          ["goodreads", "javascript;alert(1).www.goodreads.com/book/show/1-x"],
          ["goodreads", "'onx='.www.goodreads.com/book/show/1-x"],
          ["goodreads", "evil.test%2f.www.goodreads.com/book/show/1-x"],
          ["goodreads", "evil.test%00.www.goodreads.com/book/show/1-x"],
          # Cyrillic and other lookalikes in the host
          ["goodreads", "https://www.g\u043E\u043Edreads.com/book/show/1"],
          ["goodreads", "https://www.goodreads.c\u043Em/book/show/1"],
          ["amazon", "https://www.\u0430mazon.com/dp/0061054887"],
          ["amazon", "https://www.amazon.c\u043Em/dp/0061054887"],
          # Letters that fold to ASCII (long s, Kelvin sign, dotless i)
          ["goodreads", "https://www.goodread\u017F.com/book/show/1"],
          ["goodreads", "http\u017F://www.goodreads.com/book/show/1"],
          ["amazon", "https://www.amazon.co.u\u212A/dp/0061054887"],
          # Fullwidth letters, digits and delimiters
          ["goodreads", "https://www.\uFF47oodreads.com/book/show/1"],
          ["goodreads", "https://\uFF57\uFF57\uFF57.goodreads.com/book/show/1"],
          ["amazon", "https://www.amazon.\uFF43\uFF4F\uFF4D/dp/0061054887"],
          ["goodreads", "https://www.goodreads.com:\uFF14\uFF14\uFF13/book/show/1"],
          ["goodreads", "https://evil.test\uFF20www.goodreads.com/book/show/1"],
          ["goodreads", "https://evil.test\uFF0F.goodreads.com/book/show/1"],
          ["goodreads", "https://evil.test\uFF1F.goodreads.com/book/show/1"],
          ["goodreads", "https://evil.test\uFF03.goodreads.com/book/show/1"],
          ["goodreads", "https://www.goodreads.com\uFF0Fbook/show/1"],
          ["goodreads", "https\uFF1A//www.goodreads.com/book/show/1"],
          # The IDN dots and the fraction and division slashes
          ["goodreads", "https://www\u3002goodreads\u3002com/book/show/1"],
          ["goodreads", "https://www.goodreads\uFF0Ecom/book/show/1"],
          ["amazon", "https://www.amazon\uFF61com/dp/0061054887"],
          ["amazon", "https://evil.test\u2044.amazon.com/dp/0061054887"],
          ["goodreads", "https://evil.test\u2215x.goodreads.com/book/show/1"],
          # Invisible characters and a combining mark in the host, or before it after the scheme
          ["goodreads", "https://www.good\u200Breads.com/book/show/1"],
          ["goodreads", "https://\u200Bwww.goodreads.com/book/show/1"],
          ["goodreads", "https://www.goodreads.com\u200B/book/show/1"],
          ["goodreads", "www.good\u00ADreads.com/book/show/1"],
          ["amazon", "https://www.amazon\u200D.com/dp/0061054887"],
          ["amazon", "https://\u202Ewww.amazon.com/dp/0061054887"],
          ["goodreads", "https://www.goodreads\u0301.com/book/show/1"],
          # A path that only looks like the right one, and a space of any kind inside a link
          ["goodreads", "https://www.goodreads.com/book\uFF0Fshow/13651"],
          ["goodreads", "https://www.goodreads.com/book/\u017Fhow/13651"],
          ["goodreads", "https://www.goodreads.com/book/show/\uFF11\uFF13\uFF16\uFF15\uFF11"],
          ["goodreads", "https://www.goodreads.com/book/show/13651\u200B5"],
          ["amazon", "https://www.amazon.com/dp/\uFF10\uFF10\uFF16\uFF11\uFF10\uFF15\uFF14\uFF18\uFF18\uFF17"],
          ["goodreads", "https://www.goodreads.com/book/show/13651-a\u00A0https://evil.test"],
          ["goodreads", "https://www.goodreads.com/book/show/13651-a\u2028b"]
        ]

        def parse(params)
          ParseInput.call(params)
        end

        def link_key(method)
          {"goodreads" => :goodreads_url, "amazon" => :amazon_url, "isbn" => :isbn}.fetch(method)
        end

        GOODREADS.each do |url, id|
          test "goodreads #{url}" do
            result = parse(method: "goodreads", goodreads_url: url)
            assert result.success?, result.errors.inspect
            assert_equal id, result.data[:attributes][:goodreads_book_id]
            assert_equal "goodreads", result.data[:attributes][:input_method]
            assert_equal url, result.data[:attributes][:raw_input]
          end
        end

        test "goodreads fingerprint is equal across different urls for the same id" do
          a = parse(method: "goodreads", goodreads_url: GOODREADS.keys[0])
          b = parse(method: "goodreads", goodreads_url: GOODREADS.keys[2])
          assert_equal a.data[:fingerprint], b.data[:fingerprint]
        end

        AMAZON.each do |url, (asin, isbn10)|
          test "amazon #{url}" do
            result = parse(method: "amazon", amazon_url: url)
            assert result.success?, result.errors.inspect
            attrs = result.data[:attributes]
            assert_equal [asin, isbn10], [attrs[:asin], attrs[:isbn10]]
            if isbn10
              assert_equal "9780061054884", attrs[:isbn13]
            else
              assert_not attrs.key?(:isbn13)
              assert_not attrs.key?(:isbn10)
            end
          end
        end

        REFUSED.each do |method, value|
          test "refuses #{method} #{value}" do
            result = parse(:method => method, link_key(method) => value)
            assert_not result.success?
            assert_not_empty result.errors
          end
        end

        test "isbn-13 with hyphens and its isbn-10 give the same pair and fingerprint" do
          a = parse(method: "isbn", isbn: "978-0-06-105488-4")
          b = parse(method: "isbn", isbn: "0061054887")
          assert a.success? && b.success?
          assert_equal({isbn13: "9780061054884", isbn10: "0061054887"}, a.data[:attributes].slice(:isbn13, :isbn10))
          assert_equal a.data[:attributes].slice(:isbn13, :isbn10), b.data[:attributes].slice(:isbn13, :isbn10)
          assert_equal a.data[:fingerprint], b.data[:fingerprint]
        end

        test "a 979 isbn has no isbn10" do
          result = parse(method: "isbn", isbn: "9791034303793")
          assert result.success?, result.errors.inspect
          assert_equal "9791034303793", result.data[:attributes][:isbn13]
          assert_not result.data[:attributes].key?(:isbn10)
        end

        test "title and authors" do
          result = parse(method: "title_authors", title: "The Dispossessed", authors: ["Ursula K. Le Guin"])
          assert result.success?, result.errors.inspect
          assert_equal "The Dispossessed", result.data[:attributes][:typed_title]
          assert_equal ["Ursula K. Le Guin"], result.data[:attributes][:typed_author_names]
          assert_not result.data[:attributes].key?(:raw_input)
        end

        test "title and author text differing only in case and whitespace share a fingerprint" do
          a = parse(method: "title_authors", title: "The Dispossessed", authors: ["Ursula K. Le Guin"])
          b = parse(method: "title_authors", title: "  the   DISPOSSESSED ", authors: [" ursula k.  le guin"])
          assert_equal a.data[:fingerprint], b.data[:fingerprint]
        end

        test "different titles or authors differ in fingerprint" do
          a = parse(method: "title_authors", title: "A", authors: ["B"])
          b = parse(method: "title_authors", title: "A", authors: ["C"])
          assert_not_equal a.data[:fingerprint], b.data[:fingerprint]
        end

        test "fingerprints differ between methods" do
          prints = [
            parse(method: "goodreads", goodreads_url: "https://www.goodreads.com/book/show/13651"),
            parse(method: "amazon", amazon_url: "https://www.amazon.com/dp/0061054887"),
            parse(method: "isbn", isbn: "9780061054884"),
            parse(method: "title_authors", title: "13651", authors: ["x"])
          ].map { |r| r.data[:fingerprint] }
          assert_equal 4, prints.uniq.size
        end

        test "a comma inside an author name keeps it one author" do
          result = parse(method: "title_authors", title: "Why We Can't Wait", authors: ["Martin Luther King, Jr."])
          assert_equal ["Martin Luther King, Jr."], result.data[:attributes][:typed_author_names]
        end

        test "blank authors are dropped and none left is an error" do
          ok = parse(method: "title_authors", title: "T", authors: ["  ", "A", ""])
          assert_equal ["A"], ok.data[:attributes][:typed_author_names]
          none = parse(method: "title_authors", title: "T", authors: ["  ", ""])
          assert_not none.success?
          assert_match(/author/i, none.errors.join)
        end

        test "refuses too many authors, a long title and a long author" do
          assert_not parse(method: "title_authors", title: "T", authors: Array.new(11) { |i| "A#{i}" }).success?
          assert_not parse(method: "title_authors", title: "T" * 256, authors: ["A"]).success?
          assert_not parse(method: "title_authors", title: "T", authors: ["A" * 256]).success?
          assert parse(method: "title_authors", title: "T" * 255, authors: Array.new(10) { |i| "A#{i}" }).success?
        end

        test "a title is required" do
          result = parse(method: "title_authors", title: "  ", authors: ["A"])
          assert_not result.success?
          assert_match(/title/i, result.errors.join)
        end

        test "strips NUL bytes and surrounding whitespace" do
          result = parse(method: "goodreads", goodreads_url: "  https://www.goodreads.com/book/show/13651\u0000 \n")
          assert result.success?, result.errors.inspect
          assert_equal "https://www.goodreads.com/book/show/13651", result.data[:attributes][:raw_input]
          title = parse(method: "title_authors", title: "Ti\u0000tle ", authors: ["A\u0000"])
          assert_equal "Title", title.data[:attributes][:typed_title]
          assert_equal ["A"], title.data[:attributes][:typed_author_names]
        end

        # Every invisible character: the format characters (Cf) and the other ones Unicode
        # says to show as nothing (the Hangul fillers, the variation selectors).
        INVISIBLE = [*0x80..0xD7FF, *0xE000..0xFFFF, *0x1BCA0..0x1BCA3, *0xE0000..0xE007F].map { [it].pack("U") }
          .grep(/[\p{Cf}\p{Default_Ignorable_Code_Point}]/)

        test "an author or a title of nothing but invisible characters is blank" do
          assert_operator INVISIBLE.size, :>, 150
          INVISIBLE.each do |char|
            author = parse(method: "title_authors", title: "T", authors: [" #{char}#{char} "])
            assert_not author.success?, "author U+%04X" % char.ord
            assert_match(/author/i, author.errors.join)
            title = parse(method: "title_authors", title: char, authors: ["A"])
            assert_not title.success?, "title U+%04X" % char.ord
            assert_match(/title/i, title.errors.join)
          end
        end

        test "a field of another method holding only invisible characters does not count as filled" do
          result = parse(method: "isbn", isbn: "9780061054884", goodreads_url: "\u200B", title: "\uFEFF", authors: ["\u00AD"])

          assert result.success?, result.errors.inspect
        end

        test "format characters go from the ends and from inside a title and a name" do
          result = parse(method: "title_authors", title: "\uFEFF The Dis\u00ADpossessed\u200B ", authors: ["\u202A\u200BUrsula\u2060 K.\u200E Le\u200B Guin\u202C"])

          assert_equal "The Dispossessed", result.data[:attributes][:typed_title]
          assert_equal ["Ursula K. Le Guin"], result.data[:attributes][:typed_author_names]
          plain = parse(method: "title_authors", title: "The Dispossessed", authors: ["Ursula K. Le Guin"])
          assert_equal plain.data[:fingerprint], result.data[:fingerprint]
        end

        test "the joiners inside a name stay, and only those at its ends go" do
          persian = "\u0639\u0644\u06CC\u200C\u0631\u0636\u0627"
          sinhala = "\u0DC1\u0DCA\u200D\u0DBB\u0DD3"
          result = parse(method: "title_authors", title: "T", authors: ["\u200D#{persian}\u200C", sinhala])

          assert_equal [persian, sinhala], result.data[:attributes][:typed_author_names]
        end

        test "a visible mark that is technically a format character stays" do
          result = parse(method: "title_authors", title: "\u0600\u0661\u0662", authors: ["A"])

          assert_equal "\u0600\u0661\u0662", result.data[:attributes][:typed_title]
        end

        NON_ASCII_LINKS = {
          ["goodreads", "https://www.goodreads.com/book/show/13651-cien-a\u00F1os-de-soledad"] => {goodreads_book_id: 13651},
          ["goodreads", "www.goodreads.com/book/show/13651.\u0412\u043E\u0439\u043D\u0430_\u0438_\u043C\u0438\u0440"] => {goodreads_book_id: 13651},
          ["goodreads", "https://www.goodreads.com/book/show/13651?title=a\u00F1os#rese\u00F1as"] => {goodreads_book_id: 13651},
          ["goodreads", "https://www.goodreads.com/es/book/show/13651-\u{1F4D6}"] => {goodreads_book_id: 13651},
          ["amazon", "https://www.amazon.de/Gr\u00F6\u00DFe/dp/0061054887"] => {asin: "0061054887"},
          ["amazon", "https://www.amazon.co.jp/\u6307\u8F2A\u7269\u8A9E/dp/0061054887/ref=sr_1_1?__mk_ja_JP=\u30AB\u30BF\u30AB\u30CA"] => {asin: "0061054887"}
        }.freeze

        NON_ASCII_LINKS.each do |(method, link), expected|
          test "reads the raw non-ASCII #{method} link #{link}" do
            result = parse(:method => method, link_key(method) => link)

            assert result.success?, result.errors.inspect
            assert_equal expected, result.data[:attributes].slice(*expected.keys)
            assert_equal link, result.data[:attributes][:raw_input]
          end
        end

        test "invisible characters around a link are trimmed and the rest is kept as pasted" do
          link = "https://www.goodreads.com/book/show/13651"
          ["#{link}\u200B", "\uFEFF#{link}", "\u202A #{link}\u202C\n", "#{link}\u00A0\u200E"].each do |pasted|
            result = parse(method: "goodreads", goodreads_url: pasted)
            assert result.success?, pasted.inspect
            assert_equal link, result.data[:attributes][:raw_input]
            assert_equal parse(method: "goodreads", goodreads_url: link).data[:fingerprint], result.data[:fingerprint]
          end
          amazon = parse(method: "amazon", amazon_url: "https://www.amazon.com/dp/0061054887\u200B")
          assert_equal "0061054887", amazon.data[:attributes][:asin]
        end

        test "refuses a link over 2048 characters" do
          prefix = "https://www.goodreads.com/book/show/13651?"
          assert_not parse(method: "goodreads", goodreads_url: prefix + "a" * (2049 - prefix.length)).success?
          assert parse(method: "goodreads", goodreads_url: prefix + "a" * (2048 - prefix.length)).success?
        end

        test "two filled methods or another method's field is an error" do
          both = parse(method: "goodreads", goodreads_url: GOODREADS.keys[0], isbn: "9780061054884")
          assert_not both.success?
          mixed = parse(method: "title_authors", title: "T", authors: ["A"], amazon_url: AMAZON.keys[0])
          assert_not mixed.success?
          other = parse(method: "isbn", isbn: "9780061054884", title: "T")
          assert_not other.success?
          other_authors = parse(method: "isbn", isbn: "9780061054884", authors: ["A"])
          assert_not other_authors.success?
        end

        test "empty other-method fields are fine" do
          result = parse(method: "isbn", isbn: "9780061054884", goodreads_url: "", amazon_url: nil, title: " ", authors: ["", " "])
          assert result.success?, result.errors.inspect
        end

        test "an unknown or missing method is an error" do
          assert_not parse(method: "carrier_pigeon", isbn: "9780061054884").success?
          assert_not parse(isbn: "9780061054884").success?
          assert_not parse(nil).success?
        end

        test "a blank own field is an error that names what it accepts" do
          assert_match(/goodreads/i, parse(method: "goodreads", goodreads_url: "").errors.join)
          assert_match(/amazon/i, parse(method: "amazon", amazon_url: "").errors.join)
          assert_match(/isbn/i, parse(method: "isbn", isbn: "").errors.join)
        end

        test "wrong types and invalid UTF-8 never raise" do
          bad = "caf\xC3".dup.force_encoding("UTF-8")
          [
            {method: "goodreads", goodreads_url: ["x"]},
            {method: "goodreads", goodreads_url: {a: 1}},
            {method: "goodreads", goodreads_url: bad},
            {method: "isbn", isbn: bad},
            {method: "amazon", amazon_url: 12},
            {method: "title_authors", title: ["x"], authors: "A"},
            {method: "title_authors", title: bad, authors: [{a: 1}, nil, 3]},
            {method: ["goodreads"]},
            {method: "title_authors", title: "T", authors: {"0" => "A"}},
            {"method" => "isbn", "isbn" => nil}
          ].each do |params|
            result = parse(params)
            assert_not result.success?, params.inspect
            assert_not_empty result.errors
          end
        end

        test "accepts string keys and ActionController::Parameters" do
          from_strings = parse("method" => "isbn", "isbn" => "9780061054884")
          assert from_strings.success?
          params = ActionController::Parameters.new(method: "title_authors", title: "T", authors: ["A"])
          assert parse(params).success?
        end

        test "invalid utf-8 is scrubbed rather than refused when the rest is usable" do
          bad = "Caf\xC3".dup.force_encoding("UTF-8")
          result = parse(method: "title_authors", title: bad, authors: ["A"])
          assert result.success?
          assert result.data[:attributes][:typed_title].valid_encoding?
        end

        test "the attributes build a valid Books::BookSubmission for every method" do
          [
            {method: "goodreads", goodreads_url: GOODREADS.keys[0]},
            {method: "amazon", amazon_url: AMAZON.keys[0]},
            {method: "amazon", amazon_url: AMAZON.keys[1]},
            {method: "isbn", isbn: "9780061054884"},
            {method: "isbn", isbn: "9791034303793"},
            {method: "title_authors", title: "T", authors: ["A"]}
          ].each do |params|
            result = parse(params)
            assert result.success?, result.errors.inspect
            submission = ::Books::BookSubmission.new(result.data[:attributes])
            assert submission.valid?, "#{params.inspect}: #{submission.errors.full_messages}"
          end
        end
      end
    end
  end
end
