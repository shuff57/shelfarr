# frozen_string_literal: true

require "uri"
require "nokogiri"

# Client for interacting with a Library Genesis mirror (libgen.li / libgen.vg).
# Search scrapes the HTML results table; downloads resolve through the
# file.php -> ads.php -> get.php chain. Ported from the validated CWA fork
# scraper (shuff57/Calibre-Web-Automated@libgen, cps/libgen.py).
#
# libgen.is / annas-archive are widely DNS-blocked; libgen.li / .vg are not,
# so the default mirror is libgen.li and additional mirrors can be configured.
class LibGenClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class NotConfiguredError < Error; end
  class ConfigurationError < Error; end
  class ScrapingError < Error; end

  Result = Data.define(
    :file_id, :title, :author, :year,
    :file_type, :file_size, :language
  ) do
    def downloadable?
      file_id.present?
    end

    def size_human
      file_size
    end

    # Human language name (e.g. "English") used in the result title so the
    # release scorer can detect and filter on language, matching the other
    # direct sources.
    def language_display_name
      return nil if language.blank?

      info = ReleaseParserService.language_info(language)
      info ? info[:name] : language
    end
  end

  DEFAULT_BASE_URL = "https://libgen.li"
  ALLOWED_BASE_URL_SCHEMES = %w[http https].freeze
  EXTENSIONS = %w[epub pdf mobi azw3 azw fb2 djvu cbz cbr txt rtf lit].freeze
  EBOOK_EXTENSIONS = %w[epub pdf mobi azw3].freeze
  MAX_ROWS = 60
  YEAR_REGEX = /\A(?:1[89]\d{2}|20[0-2]\d)\z/
  FILE_ID_REGEX = %r{file\.php\?id=(\d+)}
  MD5_REGEX = /md5=([0-9a-fA-F]{32})/
  GET_LINK_REGEX = %r{get\.php\?md5=}

  # Known libgen.li-family mirrors, tried as fallbacks when domain rotation is
  # enabled so a dead configured mirror self-heals without manual edits. Mirrors
  # Listenarr's indexer domain auto-rotation catalog.
  # ponytail: static catalog; refresh by editing this list when domains move.
  KNOWN_MIRRORS = %w[
    https://libgen.li
    https://libgen.gs
    https://libgen.vg
    https://libgen.la
    https://libgen.bz
  ].freeze

  class << self
    # Configured when enabled and at least one mirror URL is set.
    def configured?
      SettingsService.libgen_configured?
    end

    def enabled?
      SettingsService.get(:libgen_enabled, default: false)
    end

    # Search the mirror for books. Returns an array of Result.
    # +language+ is accepted for signature parity with the other direct
    # sources; libgen.li has no reliable language query param, so it is used
    # only as a soft post-filter when results expose a language column.
    def search(query, file_types: EBOOK_EXTENSIONS, limit: search_limit, language: nil)
      ensure_configured!

      html = fetch_with_rotation(search_path(query), context: "search")
      results = parse_search_results(html, limit, file_types: file_types)
      results = prefer_language(results, language)
      Rails.logger.info "[LibGenClient] Parsed #{results.size} results for '#{query}'"
      results
    end

    # Resolve a search result's file_id into a streamable download URL.
    # Chain: /file.php?id=N -> md5 -> /ads.php?md5=MD5 -> get.php?md5=&key=.
    def get_download_url(file_id)
      ensure_configured!
      raise Error, "LibGen result is missing a file id" if file_id.blank?

      with_base_url_rotation(context: "download lookup") do |base_url|
        jar = {}
        file_page = get(base_url, "/file.php?id=#{file_id}", jar: jar)
        md5 = file_page[:body][MD5_REGEX, 1]
        raise Error, "LibGen file page did not expose an MD5 for id #{file_id}" if md5.blank?

        ads_page = get(base_url, "/ads.php?md5=#{md5}", jar: jar)
        href = Nokogiri::HTML(ads_page[:body]).at_css("a[href*='get.php?md5=']")&.[]("href")
        href ||= ads_page[:body][/href=["']([^"']*get\.php\?md5=[^"']+)["']/, 1]
        raise Error, "LibGen ads page did not expose a download link for MD5 #{md5}" if href.blank?

        URI.join("#{base_url}/ads.php", href).to_s
      end
    end

    def info_url(file_id)
      "#{preferred_base_url}/file.php?id=#{file_id}"
    end

    def search_limit
      SettingsService.get(:libgen_search_limit, default: 25)
    end

    def reset_connection!
      @connections = nil
      @working_base_url = nil
    end

    # Test connectivity by hitting the mirror root.
    def test_connection
      configured_base_urls.any? do |base_url|
        connection_for(base_url).get("/").status == 200
      rescue Faraday::Error
        false
      end
    rescue Error
      false
    end

    private

    def fetch_with_rotation(path, context:)
      with_base_url_rotation(context: context) { |base_url| get(base_url, path)[:body] }
    end

    def with_base_url_rotation(context:)
      last_error = nil

      ordered_base_urls.each do |base_url|
        return yield(base_url).tap { remember_working_mirror(base_url) }
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError, ConnectionError => e
        last_error = e
        Rails.logger.debug "[LibGenClient] #{context} failed on #{base_url}: #{e.message}"
      end

      case last_error
      when nil
        raise ConnectionError, "Failed to reach any LibGen mirror for #{context}"
      else
        raise ConnectionError, "Failed to reach any LibGen mirror for #{context}: #{last_error.message}"
      end
    end

    # GET a path, threading cookies through +jar+ so the multi-step resolve
    # chain keeps the session the mirror sets on the file page.
    def get(base_url, path, jar: nil)
      response = connection_for(base_url).get(path) do |req|
        req.headers["Cookie"] = cookie_header(jar) if jar && jar.any?
      end

      capture_cookies(jar, response) if jar
      raise ConnectionError, "LibGen request to #{path} failed with status #{response.status}" unless response.status == 200

      { body: response.body.to_s }
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, e.message
    end

    def cookie_header(jar)
      jar.map { |name, value| "#{name}=#{value}" }.join("; ")
    end

    def capture_cookies(jar, response)
      Array(response.headers["set-cookie"]).join(", ").scan(/([^=,;\s]+)=([^;,]*)/) do |name, value|
        jar[name] = value
      end
    end

    def ensure_configured!
      raise NotConfiguredError, "LibGen is not configured or enabled" unless configured?

      configured_base_urls
    end

    def connection_for(base_url)
      @connections ||= {}
      @connections[base_url] ||= Faraday.new(url: base_url) do |f|
        f.request :url_encoded
        f.adapter Faraday.default_adapter
        # A real browser UA; libgen mirrors return empty pages to some clients.
        f.headers["User-Agent"] =
          "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def configured_base_urls
      raw_url = SettingsService.get(:libgen_url, default: DEFAULT_BASE_URL).to_s
      raw_url = DEFAULT_BASE_URL if raw_url.blank?

      raw_url.split(/[,\s]+/).filter_map { |url| normalize_base_url(url.strip) }.uniq.tap do |urls|
        raise ConfigurationError, "At least one valid LibGen URL is required" if urls.empty?
      end
    end

    def normalize_base_url(url)
      return if url.blank?

      uri = URI.parse(url)
      unless ALLOWED_BASE_URL_SCHEMES.include?(uri.scheme) && uri.host.present?
        raise ConfigurationError, "LibGen URL must be a valid http or https URL"
      end
      raise ConfigurationError, "LibGen URL must not include a path" if uri.path.present? && uri.path != "/"
      if uri.query.present? || uri.fragment.present? || uri.userinfo.present?
        raise ConfigurationError, "LibGen URL must only include the site origin"
      end

      uri.to_s.delete_suffix("/")
    rescue URI::InvalidURIError => e
      raise ConfigurationError, "LibGen URL is invalid: #{e.message}"
    end

    def rotation_enabled?
      SettingsService.get(:libgen_domain_rotation_enabled, default: true)
    end

    # The full set the rotation loop may try: configured mirrors first, then the
    # known catalog (when rotation is on), normalized and deduped.
    def candidate_base_urls
      urls = configured_base_urls
      return urls unless rotation_enabled?

      catalog = KNOWN_MIRRORS.filter_map { |url| normalize_base_url(url) }
      (urls + catalog).uniq
    end

    def ordered_base_urls
      urls = candidate_base_urls
      return urls unless @working_base_url && urls.include?(@working_base_url)

      [ @working_base_url, *(urls - [ @working_base_url ]) ]
    end

    # Pin the mirror that just worked so later calls skip dead mirrors, and
    # persist it to the front of libgen_url so the choice survives restarts and
    # shows in the UI — the "remember" half of Listenarr-style rotation.
    def remember_working_mirror(base_url)
      @working_base_url = base_url
      persist_preferred_mirror(base_url) if rotation_enabled?
    end

    def persist_preferred_mirror(base_url)
      current = configured_base_urls
      return if current.first == base_url

      SettingsService.set(:libgen_url, [ base_url, *(current - [ base_url ]) ].join(", "))
    rescue StandardError => e
      Rails.logger.warn "[LibGenClient] Could not persist preferred mirror #{base_url}: #{e.message}"
    end

    def preferred_base_url
      urls = configured_base_urls
      return @working_base_url if @working_base_url && urls.include?(@working_base_url)

      urls.first
    rescue ConfigurationError
      DEFAULT_BASE_URL
    end

    def search_path(query)
      "/index.php?req=#{URI.encode_www_form_component(query)}&res=#{MAX_ROWS}"
    end

    # Parse the libgen.li results table. Each result row carries a size cell
    # linking to /file.php?id=N; the title is the row's first <b>, the author
    # the cell after it, plus heuristics for year / format / language.
    def parse_search_results(html, limit, file_types:)
      doc = Nokogiri::HTML(html)
      wanted = Array(file_types).map(&:to_s).map(&:downcase)
      results = []
      seen = Set.new

      doc.css("tr").each do |row|
        break if results.size >= limit

        link = row.at_css("a[href*='file.php?id=']")
        next unless link

        file_id = link["href"][FILE_ID_REGEX, 1]
        next if file_id.blank? || seen.include?(file_id)

        result = parse_result_row(row, file_id)
        next unless result
        next if wanted.any? && result.file_type.present? && !wanted.include?(result.file_type)

        seen << file_id
        results << result
      end

      results
    rescue => e
      Rails.logger.error "[LibGenClient] Scraping error: #{e.message}"
      raise ScrapingError, "Failed to parse LibGen results: #{e.message}"
    end

    def parse_result_row(row, file_id)
      cells = row.css("td")
      texts = cells.map { |td| td.text.to_s.squish }
      size_idx = cells.index { |td| td.at_css("a[href*='file.php?id=']") }
      return nil unless size_idx

      title = extract_title(row, texts, size_idx)
      return nil if title.blank?

      title_idx = texts.index { |t| t.include?(title[0, 20]) }
      author = (title_idx && title_idx + 1 < size_idx) ? texts[title_idx + 1] : nil

      Result.new(
        file_id: file_id,
        title: title,
        author: author.presence,
        year: extract_year(texts, size_idx),
        file_type: extract_file_type(texts, size_idx),
        file_size: texts[size_idx].presence,
        language: extract_language(texts, title_idx, size_idx)
      )
    end

    def extract_title(row, texts, size_idx)
      bold = row.at_css("b")&.text.to_s.squish
      title = bold.presence
      title ||= texts[0...size_idx].max_by(&:length)
      title&.split(";")&.first&.strip.presence || "libgen-#{texts[size_idx]}"
    end

    def extract_year(texts, size_idx)
      texts[0..(size_idx + 1)].find { |t| t.match?(YEAR_REGEX) }&.to_i
    end

    def extract_file_type(texts, size_idx)
      texts[size_idx..].map(&:downcase).find { |t| EXTENSIONS.include?(t) } ||
        texts.map(&:downcase).find { |t| EXTENSIONS.include?(t) }
    end

    # A short capitalised alpha cell between author and size is the language.
    def extract_language(texts, title_idx, size_idx)
      start = title_idx ? title_idx + 2 : 0
      cell = texts[start...size_idx].find do |t|
        t.match?(/\A[A-Z][a-zA-Z]{2,11}\z/)
      end
      return nil if cell.blank?

      info = ReleaseParserService.language_info(cell)
      return cell.downcase if info

      code, = ReleaseParserService::LANGUAGES.find { |c, i| c.casecmp?(cell) || i[:name].casecmp?(cell) }
      code || cell.downcase
    end

    def prefer_language(results, language)
      return results if language.blank?

      matching = results.select { |r| r.language.blank? || r.language == language }
      matching.presence || results
    end
  end
end
