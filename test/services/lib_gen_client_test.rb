# frozen_string_literal: true

require "test_helper"

class LibGenClientTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:libgen_enabled, true)
    SettingsService.set(:libgen_url, "https://libgen.li")
    SettingsService.set(:libgen_search_limit, 25)
    LibGenClient.reset_connection!
  end

  teardown do
    SettingsService.set(:libgen_enabled, false)
    SettingsService.set(:libgen_url, "https://libgen.li")
    LibGenClient.reset_connection!
  end

  test "configured? true when enabled with a URL" do
    assert LibGenClient.configured?
  end

  test "configured? false when disabled" do
    SettingsService.set(:libgen_enabled, false)
    assert_not LibGenClient.configured?
  end

  test "enabled? reflects the setting" do
    assert LibGenClient.enabled?
    SettingsService.set(:libgen_enabled, false)
    assert_not LibGenClient.enabled?
  end

  test "search raises NotConfiguredError when disabled" do
    SettingsService.set(:libgen_enabled, false)
    assert_raises LibGenClient::NotConfiguredError do
      LibGenClient.search("anything")
    end
  end

  test "search parses the results table" do
    VCR.turned_off do
      stub_libgen_search

      results = LibGenClient.search("test book")

      assert results.any?
      first = results.first
      assert_equal "12345", first.file_id
      assert_equal "Test Book Title", first.title
      assert_equal "Test Author", first.author
      assert_equal 2021, first.year
      assert_equal "epub", first.file_type
      assert_equal "2 MB", first.file_size
      assert first.downloadable?
    end
  end

  test "search filters out unwanted file types" do
    VCR.turned_off do
      stub_libgen_search

      results = LibGenClient.search("test book", file_types: %w[pdf])

      assert_empty results
    end
  end

  test "search rotates to the next mirror when the first fails" do
    VCR.turned_off do
      SettingsService.set(:libgen_url, "https://offline.example\nhttps://libgen.li")
      LibGenClient.reset_connection!

      stub_request(:get, /offline\.example/).to_raise(Faraday::ConnectionFailed.new("down"))
      stub_libgen_search

      results = LibGenClient.search("test book")

      assert_equal "12345", results.first.file_id
      assert_requested :get, /offline\.example/
      assert_requested :get, %r{libgen\.li/index\.php}
    end
  end

  test "search raises ConnectionError when all mirrors fail" do
    VCR.turned_off do
      # Domain rotation is on by default, so the catalog mirrors are tried too.
      stub_request(:get, /libgen\.\w+/).to_raise(Faraday::ConnectionFailed.new("down"))

      assert_raises LibGenClient::ConnectionError do
        LibGenClient.search("test book")
      end
    end
  end

  test "rotation falls back to a known catalog mirror and remembers it" do
    VCR.turned_off do
      SettingsService.set(:libgen_url, "https://libgen.li")
      LibGenClient.reset_connection!

      stub_request(:get, /libgen\.li/).to_raise(Faraday::ConnectionFailed.new("down"))
      stub_request(:get, %r{libgen\.gs/index\.php}).to_return(status: 200, body: libgen_results_html)

      results = LibGenClient.search("test book")

      assert_equal "12345", results.first.file_id
      assert_requested :get, %r{libgen\.gs/index\.php}
      # remembered: the working catalog mirror is persisted to the front of libgen_url
      assert_equal "https://libgen.gs", SettingsService.get(:libgen_url).split(/[,\s]+/).first
    end
  end

  test "rotation disabled limits search to configured mirrors" do
    VCR.turned_off do
      SettingsService.set(:libgen_domain_rotation_enabled, false)
      SettingsService.set(:libgen_url, "https://libgen.li")
      LibGenClient.reset_connection!

      stub_request(:get, %r{libgen\.li/index\.php}).to_raise(Faraday::ConnectionFailed.new("down"))

      assert_raises LibGenClient::ConnectionError do
        LibGenClient.search("test book")
      end
      assert_not_requested :get, %r{libgen\.gs}
    end
  end

  test "get_download_url resolves the file.php -> ads.php -> get.php chain" do
    VCR.turned_off do
      md5 = "abcdef0123456789abcdef0123456789"
      stub_request(:get, %r{libgen\.li/file\.php\?id=12345})
        .to_return(status: 200, body: %(<a href="ads.php?md5=#{md5}">download</a>))
      stub_request(:get, %r{libgen\.li/ads\.php\?md5=#{md5}})
        .to_return(status: 200, body: %(<a href="get.php?md5=#{md5}&key=SECRET">GET</a>))

      url = LibGenClient.get_download_url("12345")

      assert_equal "https://libgen.li/get.php?md5=#{md5}&key=SECRET", url
    end
  end

  test "get_download_url raises when the md5 is missing" do
    VCR.turned_off do
      stub_request(:get, %r{libgen\.li/file\.php\?id=999})
        .to_return(status: 200, body: "<html>no hash here</html>")

      assert_raises LibGenClient::Error do
        LibGenClient.get_download_url("999")
      end
    end
  end

  test "get_download_url raises for a blank file id" do
    assert_raises LibGenClient::Error do
      LibGenClient.get_download_url("")
    end
  end

  test "test_connection true when a mirror responds" do
    VCR.turned_off do
      stub_request(:get, "https://libgen.li/").to_return(status: 200, body: "<html></html>")
      assert LibGenClient.test_connection
    end
  end

  test "test_connection false when unreachable" do
    VCR.turned_off do
      stub_request(:get, "https://libgen.li/").to_raise(Faraday::ConnectionFailed.new("down"))
      assert_not LibGenClient.test_connection
    end
  end

  test "info_url points at the file page" do
    assert_equal "https://libgen.li/file.php?id=12345", LibGenClient.info_url("12345")
  end

  private

  # A trimmed libgen.li results row: title (<b>), author, language, year, then
  # the size cell carrying the file.php link, then the format cell.
  def libgen_results_html
    <<~HTML
      <table><tbody>
        <tr>
          <td><b>Test Book Title</b></td>
          <td>Test Author</td>
          <td>English</td>
          <td>2021</td>
          <td><a href="/file.php?id=12345">2 MB</a></td>
          <td>epub</td>
        </tr>
      </tbody></table>
    HTML
  end

  def stub_libgen_search
    stub_request(:get, %r{libgen\.li/index\.php}).to_return(status: 200, body: libgen_results_html)
  end
end
