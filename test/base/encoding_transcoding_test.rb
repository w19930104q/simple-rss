require_relative "../test_helper"
require_relative "../support/http_server"

class EncodingTranscodingTest < Test::Unit::TestCase
  include HTTPServer

  FIXTURE_DIRECTORY = File.expand_path("../data/non_utf8", __dir__)

  def fixture(name)
    File.binread(File.join(FIXTURE_DIRECTORY, name))
  end

  def assert_utf8(value, label = nil)
    assert_equal Encoding::UTF_8, value.encoding, "#{label} should be UTF-8"
    assert value.valid_encoding?, "#{label} should be valid UTF-8"
  end

  def test_iso8859_1_feed_is_transcoded_from_xml_declaration
    body = fixture("rss_iso8859_1.xml")
    assert_false body.dup.force_encoding(Encoding::UTF_8).valid_encoding?

    feed = SimpleRSS.parse(body)

    assert_utf8 feed.title, "title"
    assert_equal "Café News", feed.title
    assert_equal "Nouvelles du café", feed.description
    item = feed.items.first
    assert_utf8 item.title, "item title"
    assert_equal "Crème brûlée", item.title
    assert_equal "Métro boulot dodo", item.description
  end

  def test_utf16_feed_with_bom_and_declaration_is_transcoded
    body = fixture("rss_utf16.xml")
    assert_equal [0xFE, 0xFF], body.byteslice(0, 2).bytes

    feed = SimpleRSS.parse(body)

    assert_utf8 feed.title, "title"
    assert_equal "Héllo → wörld", feed.title
    item = feed.items.first
    assert_equal "日本語の項目", item.title
    assert_equal "絵文字 😀", item.description
  end

  def test_utf16be_feed_with_bom_but_no_declaration_uses_bom
    body = fixture("rss_utf16be_no_decl.xml")
    assert_equal [0xFE, 0xFF], body.byteslice(0, 2).bytes
    assert_nil body.dup.force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8)[/encoding=/]

    feed = SimpleRSS.parse(body)

    assert_utf8 feed.title, "title"
    assert_equal "Übernachrichten", feed.title
    assert_equal "Größe", feed.items.first.title
  end

  def test_gb18030_feed_is_transcoded_from_xml_declaration
    body = fixture("rss_gb18030.xml")

    feed = SimpleRSS.parse(body)

    assert_utf8 feed.title, "title"
    assert_equal "中文新闻", feed.title
    assert_equal "简体中文订阅", feed.description
    item = feed.items.first
    assert_utf8 item.title, "item title"
    assert_equal "头条：你好，世界", item.title
  end

  def test_http_charset_is_used_when_declaration_is_absent
    body = fixture("rss_gb18030_no_decl.xml")

    feed = SimpleRSS.parse(body, http_charset: "GB18030")

    assert_utf8 feed.title, "title"
    assert_equal "GB18030 无声明", feed.title
    assert_equal "测试条目", feed.items.first.title
  end

  def test_http_charset_tolerates_surrounding_whitespace_and_parameters
    body = fixture("rss_gb18030_no_decl.xml")

    feed = SimpleRSS.parse(body, http_charset: " GB18030 ; charset-alias=ignored")

    assert_equal "GB18030 无声明", feed.title
  end

  def test_unknown_http_charset_falls_back_to_utf8_replacement
    body = fixture("rss_iso8859_1.xml").sub(' encoding="ISO-8859-1"', "")

    feed = SimpleRSS.parse(body, http_charset: "x-not-a-real-charset")

    assert_utf8 feed.source, "source"
    assert_include feed.title, "�"
  end

  def test_xml_declaration_takes_precedence_over_http_charset
    # The body really is ISO-8859-1; the misleading HTTP charset must not win.
    body = fixture("rss_iso8859_1.xml")

    feed = SimpleRSS.parse(body, http_charset: "UTF-8")

    assert_equal "Café News", feed.title
    assert_equal "Crème brûlée", feed.items.first.title
  end

  def test_bom_takes_precedence_when_charset_conflicts
    body = fixture("rss_utf16be_no_decl.xml")

    feed = SimpleRSS.parse(body, http_charset: "ISO-8859-1")

    assert_equal "Übernachrichten", feed.title
  end

  def test_unknown_declared_encoding_falls_back_safely
    body = fixture("rss_iso8859_1.xml").sub("ISO-8859-1", "x-unknown-encoding")

    assert_nothing_raised do
      @feed = SimpleRSS.parse(body)
    end
    assert_utf8 @feed.source, "source"
    # The Latin-1 accented byte cannot be decoded without a known encoding,
    # so it becomes the replacement character rather than raising.
    assert_include @feed.title, "�"
  end

  def test_truncated_multibyte_sequence_is_replaced_not_raised
    body = fixture("rss_truncated_multibyte.xml")
    assert_false body.dup.force_encoding(Encoding::UTF_8).valid_encoding?

    feed = nil
    assert_nothing_raised(Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError) do
      feed = SimpleRSS.parse(body)
    end
    assert_utf8 feed.source, "source"
    assert_include feed.title, "�"
    assert_include feed.title, "Emoji"
  end

  def test_binary_garbage_raises_parse_error_not_encoding_error
    body = fixture("binary_garbage.bin")

    error = assert_raise(SimpleRSS::ParseError) { SimpleRSS.parse(body) }
    assert_include error.message, "binary"
    assert_kind_of SimpleRSSError, error
  end

  def test_binary_garbage_never_leaks_encoding_exceptions
    body = fixture("binary_garbage.bin")

    begin
      SimpleRSS.parse(body)
    rescue => e # rubocop:disable Style/RescueStandardError
      assert_not_kind_of Encoding::UndefinedConversionError, e
      assert_not_kind_of Encoding::InvalidByteSequenceError, e
      assert_kind_of SimpleRSS::ParseError, e
    end
  end

  def test_binary_garbage_starting_with_json_punctuation_still_raises_parse_error
    # A binary body can begin with a JSON punctuation byte by chance; it must
    # not slip through the JSON path or leak an encoding exception.
    body = "{".b + fixture("binary_garbage.bin")

    assert_raise(SimpleRSS::ParseError) { SimpleRSS.parse(body) }
  end

  def test_invalid_utf8_json_keeps_strict_json_feed_error
    source = '{"version":"https://jsonfeed.org/version/1.1","title":"x","items":[]}'.b
    source = source.sub("x", "\xFF".b)

    error = assert_raise(SimpleRSSError) { SimpleRSS.parse(source) }
    assert_include error.message, "invalid UTF-8"
    assert_not_kind_of SimpleRSS::ParseError, error
  end

  def test_existing_utf8_input_keeps_its_source_object
    body = fixture("rss_iso8859_1.xml")
               .dup.force_encoding(Encoding::ISO_8859_1)
               .encode(Encoding::UTF_8)

    feed = SimpleRSS.parse(body)

    assert_same body, feed.source
    assert_equal Encoding::UTF_8, feed.source.encoding
  end

  def test_ascii_8bit_plain_text_keeps_its_source_object
    body = "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Plain</title><link>x</link>" \
           "<description>d</description></channel></rss>".b

    feed = SimpleRSS.parse(body)

    assert_same body, feed.source
    assert_equal Encoding::ASCII_8BIT, feed.source.encoding
    assert_equal Encoding::UTF_8, feed.title.encoding
  end

  def test_fetch_transcodes_using_http_content_type_charset
    body = fixture("rss_gb18030_no_decl.xml")
    headers = { "Content-Type" => "application/rss+xml; charset=GB18030" }
    with_server([[200, headers, body]]) do |url, _requests|
      feed = SimpleRSS.fetch(url)

      assert_utf8 feed.title, "title"
      assert_equal "GB18030 无声明", feed.title
      assert_equal "测试条目", feed.items.first.title
    end
  end

  def test_fetch_transcodes_iso8859_1_without_http_charset
    body = fixture("rss_iso8859_1.xml")
    headers = { "Content-Type" => "application/rss+xml" }
    with_server([[200, headers, body]]) do |url, _requests|
      feed = SimpleRSS.fetch(url)

      assert_equal "Café News", feed.title
      assert_utf8 feed.title, "title"
    end
  end

  def test_fetch_binary_garbage_raises_parse_error
    body = fixture("binary_garbage.bin")
    with_server([[200, { "Content-Type" => "application/rss+xml" }, body]]) do |url, _requests|
      assert_raise(SimpleRSS::ParseError) { SimpleRSS.fetch(url) }
    end
  end

  def test_normalized_entries_still_work_after_transcoding
    body = fixture("rss_iso8859_1.xml")

    feed = SimpleRSS.parse(body)
    entries = feed.normalized_entries(source_url: "http://example.com/feed")

    assert_equal 1, entries.size
    assert_equal "Crème brûlée", entries.first.title
    assert_equal Encoding::UTF_8, entries.first.title.encoding
  end
end
