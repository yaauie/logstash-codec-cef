# encoding: utf-8
require "logstash/util/buftok"
require "logstash/util/charset"
require "logstash/codecs/base"
require "json"

require 'logstash/plugin_mixins/ecs_compatibility_support'

# Implementation of a Logstash codec for the ArcSight Common Event Format (CEF)
# Based on Revision 20 of Implementing ArcSight CEF, dated from June 05, 2013
# https://community.saas.hpe.com/dcvta86296/attachments/dcvta86296/connector-documentation/1116/1/CommonEventFormatv23.pdf
#
# If this codec receives a payload from an input that is not a valid CEF message, then it will
# produce an event with the payload as the 'message' field and a '_cefparsefailure' tag.
class LogStash::Codecs::CEF < LogStash::Codecs::Base
  config_name "cef"

  include LogStash::PluginMixins::ECSCompatibilitySupport(:disabled,:v1)

  # Device vendor field in CEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :vendor, :validate => :string, :default => "Elasticsearch"

  # Device product field in CEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :product, :validate => :string, :default => "Logstash"

  # Device version field in CEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :version, :validate => :string, :default => "1.0"

  # Signature ID field in CEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :signature, :validate => :string, :default => "Logstash"

  # Name field in CEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :name, :validate => :string, :default => "Logstash"

  # Severity field in CEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  #
  # Defined as field of type string to allow sprintf. The value will be validated
  # to be an integer in the range from 0 to 10 (including).
  # All invalid values will be mapped to the default of 6.
  config :severity, :validate => :string, :default => "6"

  # Fields to be included in CEV extension part as key/value pairs
  config :fields, :validate => :array, :default => []
  
  # When encoding to CEF, set this to true to adhere to the specifications and
  # encode using the CEF key name (short name) for the CEF field names.
  # Defaults to false to preserve previous behaviour that was to use the long
  # version of the CEF field names.
  config :reverse_mapping, :validate => :boolean, :default => false

  # If your input puts a delimiter between each CEF event, you'll want to set
  # this to be that delimiter.
  #
  # For example, with the TCP input, you probably want to put this:
  #
  #     input {
  #       tcp {
  #         codec => cef { delimiter => "\r\n" }
  #         # ...
  #       }
  #     }
  #
  # This setting allows the following character sequences to have special meaning:
  #
  # * `\\r` (backslash "r") - means carriage return (ASCII 0x0D)
  # * `\\n` (backslash "n") - means newline (ASCII 0x0A)
  config :delimiter, :validate => :string

  # If raw_data_field is set, during decode of an event an additional field with
  # the provided name is added, which contains the raw data.
  config :raw_data_field, :validate => :string

  # Defines whether a set of device-specific CEF fields represent the _observer_,
  # or the actual `host` on which the event occurred. If this codec handles a mix,
  # it is safe to use the default `observer`.
  config :device, :validate => %w(observer host), :default => 'observer'

  # A CEF Header is a sequence of zero or more:
  #  - backslash-escaped pipes; OR
  #  - backslash-escaped backslashes; OR
  #  - non-pipe characters
  HEADER_PATTERN = /(?:\\\||\\\\|[^|])*?/

  # Cache of a scanner pattern that _captures_ a HEADER followed by an unescaped pipe
  HEADER_SCANNER = /(#{HEADER_PATTERN})#{Regexp.quote('|')}/

  # Cache of a gsub pattern that matches a backslash-escaped backslash or backslash-escaped pipe, _capturing_ the escaped character
  HEADER_ESCAPE_CAPTURE = /\\([\\|])/

  # Cache of a gsub pattern that matches a backslash-escaped backslash or backslash-escaped equals, _capturing_ the escaped character
  EXTENSION_VALUE_ESCAPE_CAPTURE = /\\([\\=])/

  # While the original CEF spec calls out that extension keys must be alphanumeric and must not contain spaces,
  # in practice many "CEF" producers like the Arcsight smart connector produce non-legal keys including underscores,
  # commas, periods, and square-bracketed index offsets.
  #
  # To support this, we look for a specific sequence of characters that are followed by an equals sign. This pattern
  # will correctly identify all strictly-legal keys, and will also match those that include a dot-joined "subkeys" and
  # square-bracketed array indexing
  #
  # That sequence must begin with one or more `\w` (word: alphanumeric + underscore), which _optionally_ may be followed
  # by one or more "subkey" sequences and an optional square-bracketed index.
  #
  # To be understood by this implementation, a "subkey" sequence must consist of a literal dot (`.`) followed by one or
  # more characters that do not convey semantic meaning within CEF (e.g., literal-dot (`.`), literal-equals (`=`),
  # whitespace (`\s`), literal-pipe (`|`), literal-backslash ('\'), or literal-square brackets (`[` or `]`)).
  EXTENSION_KEY_PATTERN = /(?:\w+(?:\.[^\.=\s\|\\\[\]]+)*(?:\[[0-9]+\])?(?==))/

  # Some CEF extension keys seen in the wild use an undocumented array-like syntax that may not be compatible with
  # the Event API's strict-mode FieldReference parser (e.g., `fieldname[0]`).
  # Cache of a `String#sub` pattern matching array-like syntax and capturing both the base field name and the
  # array-indexing portion so we can convert to a valid FieldReference (e.g., `[fieldname][0]`).
  EXTENSION_KEY_ARRAY_CAPTURE = /^([^\[\]]+)((?:\[[0-9]+\])+)$/ # '[\1]\2'

  # In extensions, spaces may be included in an extension value without any escaping,
  # so an extension value is a sequence of zero or more:
  # - non-whitespace character; OR
  # - runs of whitespace that are NOT followed by something that looks like a key-equals sequence
  EXTENSION_VALUE_PATTERN = /(?:\S|\s++(?!#{EXTENSION_KEY_PATTERN}=))*/

  # Cache of a scanner pattern that _captures_ extension field key/value pairs
  EXTENSION_KEY_VALUE_SCANNER = /(#{EXTENSION_KEY_PATTERN})=(#{EXTENSION_VALUE_PATTERN})\s*/

  ##
  # @see CEF#sanitize_header_field
  HEADER_FIELD_SANITIZER_MAPPING = {
    "\\" => "\\\\",
    "|"  => "\\|",
    "\n" => " ",
    "\r" => " ",
  }
  HEADER_FIELD_SANITIZER_PATTERN = Regexp.union(HEADER_FIELD_SANITIZER_MAPPING.keys)
  private_constant :HEADER_FIELD_SANITIZER_MAPPING, :HEADER_FIELD_SANITIZER_PATTERN

  ##
  # @see CEF#sanitize_extension_val
  EXTENSION_VALUE_SANITIZER_MAPPING = {
    "\\" => "\\\\",
    "="  => "\\=",
    "\n" => "\\n",
    "\r" => "\\n",
  }
  EXTENSION_VALUE_SANITIZER_PATTERN = Regexp.union(EXTENSION_VALUE_SANITIZER_MAPPING.keys)
  private_constant :EXTENSION_VALUE_SANITIZER_MAPPING, :EXTENSION_VALUE_SANITIZER_PATTERN

  CEF_PREFIX = 'CEF:'.freeze

  TIMESTAMP_FIELD = '@timestamp'.freeze

  public
  def initialize(params={})
    super(params)

    # CEF input MUST be UTF-8, per the CEF White Paper that serves as the format's specification:
    # https://web.archive.org/web/20160422182529/https://kc.mcafee.com/resources/sites/MCAFEE/content/live/CORP_KNOWLEDGEBASE/78000/KB78712/en_US/CEF_White_Paper_20100722.pdf
    @utf8_charset = LogStash::Util::Charset.new('UTF-8')
    @utf8_charset.logger = self.logger

    if @delimiter
      # Logstash configuration doesn't have built-in support for escaping,
      # so we implement it here. Feature discussion for escaping is here:
      #   https://github.com/elastic/logstash/issues/1645
      @delimiter = @delimiter.gsub("\\r", "\r").gsub("\\n", "\n")
      @buffer = FileWatch::BufferedTokenizer.new(@delimiter)
    end

    generate_header_fields!
    generate_mappings!
  end

  public
  def decode(data, &block)
    if @delimiter
      @buffer.extract(data).each do |line|
        handle(line, &block)
      end
    else
      handle(data, &block)
    end
  end

  def handle(data, &block)
    event = LogStash::Event.new
    event.set(raw_data_field, data) unless raw_data_field.nil?

    @utf8_charset.convert(data)

    # Several of the many operations in the rest of this method will fail when they encounter UTF8-tagged strings
    # that contain invalid byte sequences; fail early to avoid wasted work.
    fail('invalid byte sequence in UTF-8') unless data.valid_encoding?

    # Strip any quotations at the start and end, flex connectors seem to send this
    if data[0] == "\""
      data = data[1..-2]
    end

    # Use a scanning parser to capture the HEADER_FIELDS
    unprocessed_data = data
    @header_fields.each do |field_name|
      match_data = HEADER_SCANNER.match(unprocessed_data)
      break if match_data.nil? # missing fields

      escaped_field_value = match_data[1]
      next if escaped_field_value.nil?

      # process legal header escape sequences
      unescaped_field_value = escaped_field_value.gsub(HEADER_ESCAPE_CAPTURE, '\1')

      event.set(field_name, unescaped_field_value)
      unprocessed_data = match_data.post_match
    end

    #Remainder is message
    message = unprocessed_data

    # Try and parse out the syslog header if there is one
    if (cef_version = event.get(@header_fields[0])).include?(' ')
      split_cef_version = cef_version.rpartition(' ')
      event.set(@syslog_header, split_cef_version[0])
      event.set(@header_fields[0], split_cef_version[2])
    end

    # Get rid of the CEF bit in the version
    event.set(@header_fields[0], delete_cef_prefix(event.get(@header_fields[0])))

    # Use a scanning parser to capture the Extension Key/Value Pairs
    if message && message.include?('=')
      message = message.strip

      message.scan(EXTENSION_KEY_VALUE_SCANNER) do |extension_field_key, raw_extension_field_value|
        # expand abbreviated extension field keys
        extension_field_key = @decode_mapping.fetch(extension_field_key, extension_field_key)

        # convert extension field name to strict legal field_reference, fixing field names with ambiguous array-like syntax
        extension_field_key = extension_field_key.sub(EXTENSION_KEY_ARRAY_CAPTURE, '[\1]\2') if extension_field_key.end_with?(']')

        # process legal extension field value escapes
        extension_field_value = raw_extension_field_value.gsub(EXTENSION_VALUE_ESCAPE_CAPTURE, '\1')

        if extension_field_key == TIMESTAMP_FIELD
          extension_field_value = normalize_timestamp(extension_field_value)
        end

        event.set(extension_field_key, extension_field_value)
      end
    end

    yield event
  rescue => e
    @logger.error("Failed to decode CEF payload. Generating failure event with payload in message field.",
                  :exception => e.class, :message => e.message, :backtrace => e.backtrace, :data => data)
    yield LogStash::Event.new("message" => data, "tags" => ["_cefparsefailure"])
  end

  public
  def encode(event)
    # "CEF:0|Elasticsearch|Logstash|1.0|Signature|Name|Sev|"

    vendor = sanitize_header_field(event.sprintf(@vendor))
    vendor = self.class.get_config["vendor"][:default] if vendor.empty?

    product = sanitize_header_field(event.sprintf(@product))
    product = self.class.get_config["product"][:default] if product.empty?

    version = sanitize_header_field(event.sprintf(@version))
    version = self.class.get_config["version"][:default] if version.empty?

    signature = sanitize_header_field(event.sprintf(@signature))
    signature = self.class.get_config["signature"][:default] if signature.empty?

    name = sanitize_header_field(event.sprintf(@name))
    name = self.class.get_config["name"][:default] if name.empty?

    severity = sanitize_severity(event, @severity)

    # Should also probably set the fields sent
    header = ["CEF:0", vendor, product, version, signature, name, severity].join("|")
    values = @fields.map { |fieldname| get_value(fieldname, event) }.compact.join(" ")

    @on_event.call(event, "#{header}|#{values}#{@delimiter}")
  end

  private

  def generate_header_fields!
    # @header_fields is an _ordered_ set of fields.
    @header_fields = [
      ecs_select[disabled: 'cefVersion',         v1: '[cef][version]'],
      ecs_select[disabled: 'deviceVendor',       v1: '[observer][vendor]'],
      ecs_select[disabled: 'deviceProduct',      v1: '[observer][product]'],
      ecs_select[disabled: 'deviceVersion',      v1: '[observer][version]'],
      ecs_select[disabled: 'deviceEventClassId', v1: '[event][code]'],
      ecs_select[disabled: 'name',               v1: '[cef][name]'],
      ecs_select[disabled: 'severity',           v1: '[event][severity]']
    ].map(&:freeze).freeze
    # the @syslog_header is the field name used when a syslog header preceeds the CEF Version.
    @syslog_header = ecs_select[disabled:'syslog',v1:'[log][syslog][header]']
  end

  class CEFField
    ##
    # @param name [String]: the full CEF name of a field
    # @param key [String] (optional): an abbreviated CEF key to use when encoding a value with `reverse_mapping => true`
    #                                 when left unspecified, the `key` is the field's `name`.
    # @param ecs_field [String] (optional): an ECS-compatible field reference to use, with square-bracket syntax.
    #                                 when left unspecified, the `ecs_field` is the field's `name`.
    def initialize(name, key: name, ecs_field: name)
      @name = name
      @key = key
      @ecs_field = ecs_field
    end
    attr_reader :name
    attr_reader :key
    attr_reader :ecs_field
  end

  def generate_mappings!
    encode_mapping = Hash.new
    decode_mapping = Hash.new
    [
      CEFField.new("deviceAction",                    key: "act",       ecs_field: "[event][action]"),
      CEFField.new("applicationProtocol",             key: "app",       ecs_field: "[network][protocol]"),
      CEFField.new("deviceCustomIPv6Address1",        key: "c6a1",      ecs_field: "[cef][device_custom_ipv6_address_1][value]"),
      CEFField.new("deviceCustomIPv6Address1Label",   key: "c6a1Label", ecs_field: "[cef][device_custom_ipv6_address_1][label]"),
      CEFField.new("deviceCustomIPv6Address2",        key: "c6a2",      ecs_field: "[cef][device_custom_ipv6_address_2][value]"),
      CEFField.new("deviceCustomIPv6Address2Label",   key: "c6a2Label", ecs_field: "[cef][device_custom_ipv6_address_2][label]"),
      CEFField.new("deviceCustomIPv6Address3",        key: "c6a3",      ecs_field: "[cef][device_custom_ipv6_address_3][value]"),
      CEFField.new("deviceCustomIPv6Address3Label",   key: "c6a3Label", ecs_field: "[cef][device_custom_ipv6_address_3][label]"),
      CEFField.new("deviceCustomIPv6Address4",        key: "c6a4",      ecs_field: "[cef][device_custom_ipv6_address_4][value]"),
      CEFField.new("deviceCustomIPv6Address4Label",   key: "c6a4Label", ecs_field: "[cef][device_custom_ipv6_address_4][label]"),
      CEFField.new("deviceEventCategory",             key: "cat",       ecs_field: "[cef][category]"),
      CEFField.new("deviceCustomFloatingPoint1",      key: "cfp1",      ecs_field: "[cef][device_custom_floating_point_1][value]"),
      CEFField.new("deviceCustomFloatingPoint1Label", key: "cfp1Label", ecs_field: "[cef][device_custom_floating_point_1][label]"),
      CEFField.new("deviceCustomFloatingPoint2",      key: "cfp2",      ecs_field: "[cef][device_custom_floating_point_2][value]"),
      CEFField.new("deviceCustomFloatingPoint2Label", key: "cfp2Label", ecs_field: "[cef][device_custom_floating_point_2][label]"),
      CEFField.new("deviceCustomFloatingPoint3",      key: "cfp3",      ecs_field: "[cef][device_custom_floating_point_3][value]"),
      CEFField.new("deviceCustomFloatingPoint3Label", key: "cfp3Label", ecs_field: "[cef][device_custom_floating_point_3][label]"),
      CEFField.new("deviceCustomFloatingPoint4",      key: "cfp4",      ecs_field: "[cef][device_custom_floating_point_4][value]"),
      CEFField.new("deviceCustomFloatingPoint4Label", key: "cfp4Label", ecs_field: "[cef][device_custom_floating_point_4][label]"),
      CEFField.new("deviceCustomNumber1",             key: "cn1",       ecs_field: "[cef][device_custom_number_1][value]"),
      CEFField.new("deviceCustomNumber1Label",        key: "cn1Label",  ecs_field: "[cef][device_custom_number_1][label]"),
      CEFField.new("deviceCustomNumber2",             key: "cn2",       ecs_field: "[cef][device_custom_number_2][value]"),
      CEFField.new("deviceCustomNumber2Label",        key: "cn2Label",  ecs_field: "[cef][device_custom_number_2][label]"),
      CEFField.new("deviceCustomNumber3",             key: "cn3",       ecs_field: "[cef][device_custom_number_3][value]"),
      CEFField.new("deviceCustomNumber3Label",        key: "cn3Label",  ecs_field: "[cef][device_custom_number_3][label]"),
      CEFField.new("baseEventCount",                  key: "cnt",       ecs_field: "[cef][base_event_count]"),
      CEFField.new("deviceCustomString1",             key: "cs1",       ecs_field: "[cef][device_custom_string_1][value]"),
      CEFField.new("deviceCustomString1Label",        key: "cs1Label",  ecs_field: "[cef][device_custom_string_1][label]"),
      CEFField.new("deviceCustomString2",             key: "cs2",       ecs_field: "[cef][device_custom_string_2][value]"),
      CEFField.new("deviceCustomString2Label",        key: "cs2Label",  ecs_field: "[cef][device_custom_string_2][label]"),
      CEFField.new("deviceCustomString3",             key: "cs3",       ecs_field: "[cef][device_custom_string_3][value]"),
      CEFField.new("deviceCustomString3Label",        key: "cs3Label",  ecs_field: "[cef][device_custom_string_3][label]"),
      CEFField.new("deviceCustomString4",             key: "cs4",       ecs_field: "[cef][device_custom_string_4][value]"),
      CEFField.new("deviceCustomString4Label",        key: "cs4Label",  ecs_field: "[cef][device_custom_string_4][label]"),
      CEFField.new("deviceCustomString5",             key: "cs5",       ecs_field: "[cef][device_custom_string_5][value]"),
      CEFField.new("deviceCustomString5Label",        key: "cs5Label",  ecs_field: "[cef][device_custom_string_5][label]"),
      CEFField.new("deviceCustomString6",             key: "cs6",       ecs_field: "[cef][device_custom_string_6][value]"),
      CEFField.new("deviceCustomString6Label",        key: "cs6Label",  ecs_field: "[cef][device_custom_string_6][label]"),
      CEFField.new("destinationHostName",             key: "dhost",     ecs_field: "[destination][domain]"),
      CEFField.new("destinationMacAddress",           key: "dmac",      ecs_field: "[destination][mac]"),
      CEFField.new("destinationNtDomain",             key: "dntdom",    ecs_field: "[destination][registered_domain]"),
      CEFField.new("destinationProcessId",            key: "dpid",      ecs_field: "[destination][process][pid]"),
      CEFField.new("destinationUserPrivileges",       key: "dpriv",     ecs_field: "[destination][user][group][name]"),
      CEFField.new("destinationProcessName",          key: "dproc",     ecs_field: "[destination][process][name]"),
      CEFField.new("destinationPort",                 key: "dpt",       ecs_field: "[destination][port]"),
      CEFField.new("destinationAddress",              key: "dst",       ecs_field: "[destination][ip]"),
      CEFField.new("destinationUserId",               key: "duid",      ecs_field: "[destination][user][id]"),
      CEFField.new("destinationUserName",             key: "duser",     ecs_field: "[destination][user][name]"),
      CEFField.new("deviceAddress",                   key: "dvc",       ecs_field: "[#{@device}][ip]"),
      CEFField.new("deviceHostName",                  key: "dvchost",   ecs_field: "[#{@device}][name]"),
      CEFField.new("deviceProcessId",                 key: "dvcpid",    ecs_field: "[process][pid]"),
      CEFField.new("endTime",                         key: "end",       ecs_field: "[event][end]"),
      CEFField.new("fileName",                        key: "fname",     ecs_field: "[file][name]"),
      CEFField.new("fileSize",                        key: "fsize",     ecs_field: "[file][size]"),
      CEFField.new("bytesIn",                         key: "in",        ecs_field: "[source][bytes]"),
      CEFField.new("message",                         key: "msg",       ecs_field: "[message]"),
      CEFField.new("bytesOut",                        key: "out",       ecs_field: "[destination][bytes]"),
      CEFField.new("eventOutcome",                    key: "outcome",   ecs_field: "[event][outcome]"),
      CEFField.new("transportProtocol",               key: "proto",     ecs_field: "[network][transport]"),
      CEFField.new("requestUrl",                      key: "request",   ecs_field: "[url][original]"),
      CEFField.new("deviceReceiptTime",               key: "rt",        ecs_field: "@timestamp"),
      CEFField.new("sourceHostName",                  key: "shost",     ecs_field: "[source][domain]"),
      CEFField.new("sourceMacAddress",                key: "smac",      ecs_field: "[source][mac]"),
      CEFField.new("sourceNtDomain",                  key: "sntdom",    ecs_field: "[source][registered_domain]"),
      CEFField.new("sourceProcessId",                 key: "spid",      ecs_field: "[source][process][pid]"),
      CEFField.new("sourceUserPrivileges",            key: "spriv",     ecs_field: "[source][user][group][name]"),
      CEFField.new("sourceProcessName",               key: "sproc",     ecs_field: "[source][process][name]"),
      CEFField.new("sourcePort",                      key: "spt",       ecs_field: "[source][port]"),
      CEFField.new("sourceAddress",                   key: "src",       ecs_field: "[source][ip]"),
      CEFField.new("startTime",                       key: "start",     ecs_field: "[event][start]"),
      CEFField.new("sourceUserId",                    key: "suid",      ecs_field: "[source][user][id]"),
      CEFField.new("sourceUserName",                  key: "suser",     ecs_field: "[source][user][name]"),
      CEFField.new("agentHostName",                   key: "ahost",     ecs_field: "[agent][name]"),
      CEFField.new("agentReceiptTime",                key: "art",       ecs_field: "[event][created]"),
      CEFField.new("agentType",                       key: "at",        ecs_field: "[agent][type]"),
      CEFField.new("agentId",                         key: "aid",       ecs_field: "[agent][id]"),
      CEFField.new("cefVersion",                      key: "_cefVer",   ecs_field: "[cef][version]"),
      CEFField.new("agentAddress",                    key: "agt",       ecs_field: "[agent][ip]"),
      CEFField.new("agentVersion",                    key: "av",        ecs_field: "[agent][version]"),
      CEFField.new("agentTimeZone",                   key: "atz",       ecs_field: "[agent][timezone]"),
      CEFField.new("destinationTimeZone",             key: "dtz",       ecs_field: "[event][timezone]"),
      CEFField.new("sourceLongitude",                 key: "slong",     ecs_field: "[source][geo][location][lon]"),
      CEFField.new("sourceLatitude",                  key: "slat",      ecs_field: "[source][geo][location][lat]"),
      CEFField.new("destinationLongitude",            key: "dlong",     ecs_field: "[destination][geo][location][lon]"),
      CEFField.new("destinationLatitude",             key: "dlat",      ecs_field: "[destination][geo][location][lon]"),
      CEFField.new("categoryDeviceType",              key: "catdt",     ecs_field: "[cef][device_type]"),
      CEFField.new("managerReceiptTime",              key: "mrt",       ecs_field: "[event][ingested]"),
      CEFField.new("agentMacAddress",                 key: "amac",      ecs_field: "[agent][mac]"),
      CEFField.new("requestMethod",                                     ecs_field: "[http][request][method]"),
      CEFField.new("requestClientApplication",                          ecs_field: "[user_agent][original]"),
    ].compact.each do |cef|
      field_name = ecs_select[disabled:cef.name, v1:cef.ecs_field]

      # whether the source is a cef_key or cef_name, normalize to field_name
      decode_mapping[cef.key]  = field_name
      decode_mapping[cef.name] = field_name

      # whether source is a cef_name or a field_name, normalize to target
      normalized_encode_target = @reverse_mapping ? cef.key : cef.name
      encode_mapping[field_name] = normalized_encode_target
      encode_mapping[cef.name] ||= normalized_encode_target
    end

    @decode_mapping = decode_mapping.dup.freeze
    @encode_mapping = encode_mapping.dup.freeze
  end

  # Escape pipes and backslashes in the header. Equal signs are ok.
  # Newlines are forbidden.
  def sanitize_header_field(value)
    value.to_s
         .gsub("\r\n", "\n")
         .gsub(HEADER_FIELD_SANITIZER_PATTERN, HEADER_FIELD_SANITIZER_MAPPING)
  end

  # Keys must be made up of a single word, with no spaces
  # must be alphanumeric
  def sanitize_extension_key(value)
    value.to_s
         .gsub(/[^a-zA-Z0-9]/, "")
  end

  # Escape equal signs in the extensions. Canonicalize newlines.
  # CEF spec leaves it up to us to choose \r or \n for newline.
  # We choose \n as the default.
  def sanitize_extension_val(value)
    value.to_s
         .gsub("\r\n", "\n")
         .gsub(EXTENSION_VALUE_SANITIZER_PATTERN, EXTENSION_VALUE_SANITIZER_MAPPING)
  end

  def normalize_timestamp(value)
    time = case value
           when Time then value
           when String then Time.parse(value)
           when Number then Time.at(value)
           else fail("Failed to normalize time `#{value.inspect}`")
           end
    LogStash::Timestamp.new(time)
  end

  def get_value(fieldname, event)
    val = event.get(fieldname)

    return nil if val.nil?

    key = @encode_mapping.fetch(fieldname, fieldname)
    key = sanitize_extension_key(key)

    case val
    when Array, Hash
      return "#{key}=#{sanitize_extension_val(val.to_json)}"
    when LogStash::Timestamp
      return "#{key}=#{val.to_s}"
    else
      return "#{key}=#{sanitize_extension_val(val)}"
    end
  end

  def sanitize_severity(event, severity)
    severity = sanitize_header_field(event.sprintf(severity)).strip
    severity = self.class.get_config["severity"][:default] unless valid_severity?(severity)
    severity.to_i.to_s
  end

  def valid_severity?(sev)
    f = Float(sev)
    # check if it's an integer or a float with no remainder
    # and if the value is between 0 and 10 (inclusive)
    (f % 1 == 0) && f.between?(0,10)
  rescue TypeError, ArgumentError
    false
  end

  if Gem::Requirement.new(">= 2.5.0").satisfied_by? Gem::Version.new(RUBY_VERSION)
    def delete_cef_prefix(cef_version)
      cef_version.delete_prefix(CEF_PREFIX)
    end
  else
    def delete_cef_prefix(cef_version)
      cef_version.start_with?(CEF_PREFIX) ? cef_version[CEF_PREFIX.length..-1] : cef_version
    end
  end
end
