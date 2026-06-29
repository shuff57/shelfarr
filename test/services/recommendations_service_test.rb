# frozen_string_literal: true

require "test_helper"

class RecommendationsServiceTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "returns empty when no metadata provider is available" do
    MetadataService.stub :available?, false do
      assert_empty RecommendationsService.call(@user)
    end
  end

  test "recommends books from followed authors, excluding library items" do
    @user.author_follows.create!(author_name: "Jane Austen", book_type: :ebook)
    fresh = build_candidate(title: "Emma", author: "Jane Austen", work_id: "hardcover:42")

    with_metadata([ fresh ]) do
      results = RecommendationsService.call(@user)
      assert_equal [ "Emma" ], results.map(&:title)
    end
  end

  test "excludes candidates already in the user's library" do
    @user.author_follows.create!(author_name: "Jane Austen", book_type: :ebook)
    book = Book.create!(title: "Emma", author: "Jane Austen", book_type: :ebook, hardcover_id: "42")
    @user.requests.create!(book: book, status: :pending, created_via: "web")
    existing = build_candidate(title: "Emma", author: "Jane Austen", work_id: "hardcover:42")

    with_metadata([ existing ]) do
      assert_empty RecommendationsService.call(@user)
    end
  end

  private

  def with_metadata(candidates)
    MetadataService.stub :available?, true do
      MetadataService.stub :search, ->(*, **) { candidates } do
        yield
      end
    end
  end

  def build_candidate(title:, author:, work_id:)
    source, source_id = work_id.split(":", 2)
    MetadataSearch::Candidate.new(
      canonical_key: work_id, title: title, author: author, year: 2000,
      description: nil, cover_url: nil, series_name: nil, series_position: nil,
      has_ebook: true, has_audiobook: false,
      sources: [ { source: source, source_id: source_id, source_name: source.titleize, source_url: nil, work_id: work_id } ],
      editions: [], confidence: 90
    )
  end
end
