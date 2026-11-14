# rbs_inline: enabled

class SimpleRSS
  # Converts feed bodies that are not valid UTF-8 into a UTF-8 string the
  # regex-based parser can consume.
  #
  # The effective encoding is resolved in this order:
  #
  # 1. the +encoding+ attribute of the XML declaration
  # 2. the charset advertised by the HTTP +Content-Type+ header
  # 3. the byte order mark (BOM) at the start of the document
  #
  # When none of them yields a usable encoding, the bytes are treated as
  # UTF-8 with invalid sequences replaced by the Unicode replacement
  # character. Input that is pure binary garbage rather than text raises
  # SimpleRSS::ParseError instead of leaking an Encoding exception.
  class EncodingHandler
    REPLACEMENT_CHARACTER = "�"

    # @rbs @source: String
    # @rbs @http_charset: String?

    BOMS = [
      ["\xEF\xBB\xBF".b, Encoding::UTF_8],
      ["\xFF\xFE\x00\x00".b, Encoding::UTF_32LE],
      ["\x00\x00\xFE\xFF".b, Encoding::UTF_32BE],
      ["\xFF\xFE".b, Encoding::UTF_16LE],
      ["\xFE\xFF".b, Encoding::UTF_16BE]
    ].freeze #: Array[[String, Encoding]]

    XML_DECLARATION_PATTERN = /\A\s*<\?xml\b[^?]*\?>/m
    XML_DECLARATION_BYTES_PATTERN = Regexp.new(XML_DECLARATION_PATTERN.source, Regexp::MULTILINE | Regexp::NOENCODING)
    ENCODING_ATTRIBUTE_PATTERN = /\bencoding\s*=\s*(['"])([A-Za-z][A-Za-z0-9._-]*)\1/

    # @rbs (String, ?String?) -> void
    def initialize(source, http_charset = nil)
      @source = source.dup.force_encoding(Encoding::ASCII_8BIT)
      @http_charset = http_charset
    end

    # @rbs () -> String
    def normalize
      bom_encoding = detect_bom
      without_bom = strip_bom(@source)
      encoding = declared_encoding(without_bom, bom_encoding)

      # Generic UTF-16/UTF-32 encodings determine endianness from the BOM, so
      # the BOM must stay in place for them. Specific endian encodings and
      # UTF-8 consume the body without the BOM.
      keep_bom = encoding.nil? ? bom_encoding : generic_wide_encoding?(encoding)
      body = keep_bom ? @source : without_bom
      effective_encoding = encoding || bom_encoding

      converted = transcode(body, effective_encoding)
      raise ParseError, "Feed body is binary data, not an XML or JSON document" if binary_garbage?(converted)

      converted
    end

    class << self
      # @rbs (Encoding, Encoding?) -> bool
      def compatible_with_bom?(encoding, bom_encoding)
        return true unless bom_encoding

        bom_family = bom_encoding.name.start_with?("UTF-16") ? "UTF-16" : "UTF-32"
        encoding.name.start_with?(bom_family)
      end

      # Whether the given source needs transcoding. Valid UTF-8 text (including
      # ASCII-only bodies tagged ASCII-8BIT) keeps its original object so the
      # existing parser contracts are preserved byte for byte.
      #
      # @rbs (String, ?String?) -> bool
      def needs_normalization?(source, http_charset = nil)
        charset_name = http_charset && normalized_charset_name(http_charset)
        return true if charset_name && charset_name != "UTF-8"

        bytes = source.dup.force_encoding(Encoding::ASCII_8BIT)
        bom = BOMS.find { |mark, _encoding| bytes.start_with?(mark) }
        # A UTF-8 BOM on otherwise valid UTF-8 is already handled by the
        # parser; keeping that path preserves the original source object.
        if bom
          return bom.last != Encoding::UTF_8
        end

        utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
        !utf8.valid_encoding?
      end

      # @rbs (String) -> String?
      def normalized_charset_name(charset)
        encoding = Encoding.find(charset.split(";", 2).first.to_s.strip)
        encoding.name
      rescue ArgumentError
        nil
      end

      # Whether raw bytes are binary garbage rather than misencoded text.
      # Text documents never contain NUL bytes, and bodies dominated by
      # non-printable control bytes cannot be a feed even if a few bytes
      # happen to match XML or JSON punctuation.
      #
      # @rbs (String) -> bool
      def binary?(source)
        bytes = source.dup.force_encoding(Encoding::ASCII_8BIT)
        return false if bytes.empty?
        return true if bytes.include?("\u0000".b)

        controls = bytes.bytes.count { |byte| binary_control_byte?(byte) }
        controls > (bytes.bytesize / 2)
      end

      # @rbs (Integer) -> bool
      def binary_control_byte?(byte)
        byte < 0x20 && ![0x09, 0x0A, 0x0D].include?(byte)
      end

      # Whether the bytes start with a UTF-16 or UTF-32 byte order mark.
      #
      # @rbs (String) -> bool
      def wide_bom?(source)
        bytes = source.dup.force_encoding(Encoding::ASCII_8BIT)
        BOMS.any? { |mark, encoding| encoding != Encoding::UTF_8 && bytes.start_with?(mark) }
      end
    end

    private

    # @rbs () -> Encoding?
    def detect_bom
      BOMS.find { |mark, _encoding| @source.start_with?(mark) }&.last
    end

    # @rbs (String) -> String
    def strip_bom(bytes)
      mark = BOMS.map(&:first).find { |prefix| bytes.start_with?(prefix) }
      return bytes unless mark

      bytes.byteslice(mark.bytesize, bytes.bytesize - mark.bytesize) || +"".b
    end

    # @rbs (String, Encoding?) -> Encoding?
    def declared_encoding(bytes, bom_encoding)
      extract_declared_encoding(bytes, bom_encoding) || http_encoding(bom_encoding) || bom_encoding
    end

    # @rbs (Encoding?) -> Encoding?
    def http_encoding(bom_encoding = nil)
      name = self.class.normalized_charset_name(@http_charset.to_s)
      encoding = name && Encoding.find(name)
      encoding if encoding.nil? || self.class.compatible_with_bom?(encoding, bom_encoding)
    end

    # @rbs (String, Encoding?) -> Encoding?
    def extract_declared_encoding(bytes, bom_encoding)
      declaration = read_xml_declaration(bytes, bom_encoding)
      return unless declaration

      match = declaration.match(ENCODING_ATTRIBUTE_PATTERN)
      return unless match

      begin
        encoding = Encoding.find(match[2])
      rescue ArgumentError
        return nil
      end
      encoding if self.class.compatible_with_bom?(encoding, bom_encoding)
    end

    # The declaration itself is ASCII text, but in UTF-16/32 documents each
    # ASCII character occupies two or four bytes. Decode just enough of the
    # document to read the declaration, falling back to byte-level matching
    # for ASCII-compatible encodings.
    #
    # @rbs (String, Encoding?) -> String?
    def read_xml_declaration(bytes, bom_encoding)
      if bom_encoding && wide_encoding?(bom_encoding)
        # Read from the intact BOM-marked body with the generic encoding so
        # endianness is detected rather than assumed from the BOM constant.
        head = @source.byteslice(0, [512, @source.bytesize].min).force_encoding(generic_wide_name(bom_encoding))
        head = head.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT_CHARACTER)
        declaration = head[XML_DECLARATION_PATTERN]
        return declaration if declaration
      end

      head = bytes.byteslice(0, [256, bytes.bytesize].min).to_s
      head[XML_DECLARATION_BYTES_PATTERN]
    end

    # @rbs (Encoding) -> Encoding
    def generic_wide_name(encoding)
      name = encoding.name
      name.start_with?("UTF-16") ? Encoding::UTF_16 : Encoding::UTF_32
    end

    # @rbs (Encoding) -> bool
    def wide_encoding?(encoding)
      [Encoding::UTF_16BE, Encoding::UTF_16LE, Encoding::UTF_32BE, Encoding::UTF_32LE].include?(encoding)
    end

    # @rbs (Encoding) -> bool
    def generic_wide_encoding?(encoding)
      [Encoding::UTF_16, Encoding::UTF_32].include?(encoding)
    end

    # @rbs (String, Encoding?) -> String
    def transcode(bytes, encoding)
      return bytes.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT_CHARACTER) unless encoding

      bytes.dup.force_encoding(encoding)
           .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT_CHARACTER)
    rescue EncodingError
      bytes.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT_CHARACTER)
    end

    # Text feeds always carry XML or JSON punctuation, but random binary
    # bytes can contain the same punctuation by chance. A decoded body that
    # is dominated by replacement characters and control bytes never held
    # text, and NUL bytes cannot appear in a real transcoded feed.
    #
    # @rbs (String) -> bool
    def binary_garbage?(text)
      return false if text.empty?
      return true if text.include?("\u0000")

      suspicious = text.each_char.count { |char| char == REPLACEMENT_CHARACTER || nontext_control?(char) }
      suspicious > (text.length / 2)
    end

    # @rbs (String) -> bool
    def nontext_control?(char)
      codepoint = char.ord
      codepoint < 0x20 && !["\t", "\n", "\r"].include?(char)
    end
  end
end
