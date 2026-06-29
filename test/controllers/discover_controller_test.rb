# frozen_string_literal: true

require "test_helper"

class DiscoverControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
  end

  test "renders the discover page" do
    get discover_path
    assert_response :success
  end

  test "renders recommendations when available" do
    candidate = MetadataSearch::Candidate.new(
      canonical_key: "hardcover:42", title: "Emma", author: "Jane Austen", year: 1815,
      description: nil, cover_url: nil, series_name: nil, series_position: nil,
      has_ebook: true, has_audiobook: false,
      sources: [ { source: "hardcover", source_id: "42", source_name: "Hardcover", source_url: nil, work_id: "hardcover:42" } ],
      editions: [], confidence: 90
    )

    RecommendationsService.stub :call, [ candidate ] do
      get discover_path
    end

    assert_response :success
    assert_select "h3", text: /Emma/
  end

  test "requires authentication" do
    sign_out
    get discover_path
    assert_redirected_to new_session_path
  end
end
