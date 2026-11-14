# Generates the non-UTF-8 feed fixtures used by EncodingTranscodingTest.
# Run from the repository root:
#
#   ruby test/support/generate_encoding_fixtures.rb
#
# The generated files are committed alongside the generator so the test
# suite does not depend on the machine's locale or external tools.
require "fileutils"

FIXTURE_DIRECTORY = File.expand_path("../data/non_utf8", __dir__)

RSS_TEMPLATE_WITH_DECLARATION = <<~XML
  <?xml version="1.0" encoding="%<declaration>s"?>
  <rss version="2.0">
    <channel>
      <title>%<title>s</title>
      <link>http://example.com/feed</link>
      <description>%<description>s</description>
      <item>
        <title>%<item_title>s</title>
        <link>http://example.com/item/1</link>
        <description>%<item_description>s</description>
      </item>
    </channel>
  </rss>
XML

RSS_TEMPLATE_WITHOUT_DECLARATION = <<~XML
  <?xml version="1.0"?>
  <rss version="2.0">
    <channel>
      <title>%<title>s</title>
      <link>http://example.com/feed</link>
      <description>%<description>s</description>
      <item>
        <title>%<item_title>s</title>
        <link>http://example.com/item/1</link>
        <description>%<item_description>s</description>
      </item>
    </channel>
  </rss>
XML

def write_fixture(name, bytes)
  path = File.join(FIXTURE_DIRECTORY, name)
  File.binwrite(path, bytes)
  puts "wrote #{path} (#{bytes.bytesize} bytes)"
end

FileUtils.mkdir_p(FIXTURE_DIRECTORY)

# ISO-8859-1 (Latin-1) feed with an explicit XML declaration.
latin1 = RSS_TEMPLATE_WITH_DECLARATION % {
  declaration: "ISO-8859-1",
  title: "Café News",
  description: "Nouvelles du café",
  item_title: "Crème brûlée",
  item_description: "Métro boulot dodo"
}
write_fixture("rss_iso8859_1.xml", latin1.encode(Encoding::ISO_8859_1))

# UTF-16 (BOM marks endianness; declaration names the generic family).
utf16 = RSS_TEMPLATE_WITH_DECLARATION % {
  declaration: "UTF-16",
  title: "Héllo → wörld",
  description: "Unicode feed",
  item_title: "日本語の項目",
  item_description: "絵文字 😀"
}
write_fixture("rss_utf16.xml", utf16.encode(Encoding::UTF_16))

# UTF-16BE with BOM but no encoding attribute in the declaration.
utf16be = RSS_TEMPLATE_WITHOUT_DECLARATION % {
  title: "Übernachrichten",
  description: "UTF-16BE feed",
  item_title: "Größe",
  item_description: "Einheitsgröße"
}
write_fixture("rss_utf16be_no_decl.xml", "\xFE\xFF".b + utf16be.encode(Encoding::UTF_16BE).b)

# GB18030 feed with an explicit XML declaration.
gb18030 = RSS_TEMPLATE_WITH_DECLARATION % {
  declaration: "GB18030",
  title: "中文新闻",
  description: "简体中文订阅",
  item_title: "头条：你好，世界",
  item_description: "这是一个 GB18030 编码的订阅源"
}
write_fixture("rss_gb18030.xml", gb18030.encode(Encoding::GB18030))

# GB18030 feed without any declaration; the charset arrives over HTTP.
gb18030_no_decl = RSS_TEMPLATE_WITHOUT_DECLARATION % {
  title: "GB18030 无声明",
  description: "字符集由 HTTP 头提供",
  item_title: "测试条目",
  item_description: "回退到 Content-Type charset"
}
write_fixture("rss_gb18030_no_decl.xml", gb18030_no_decl.encode(Encoding::GB18030))

# Valid UTF-8 feed with a four-byte emoji whose last byte is removed, leaving
# a truncated multibyte sequence in the middle of the title.
truncated_source = RSS_TEMPLATE_WITH_DECLARATION % {
  declaration: "UTF-8",
  title: "Emoji 😀 feed",
  description: "truncated multibyte sequence",
  item_title: "Item 😀",
  item_description: "The emoji byte sequence is cut short"
}
truncated = truncated_source.b
emoji_start = truncated.index("\xF0".b)
title_end = truncated.index("</title>".b, emoji_start)
truncated = truncated.byteslice(0, emoji_start + 2) + " feed" + truncated.byteslice(title_end..)
write_fixture("rss_truncated_multibyte.xml", truncated)

# Pure binary garbage: every byte value in random order, no text structure.
write_fixture("binary_garbage.bin", (0..255).to_a.shuffle.pack("C*"))
