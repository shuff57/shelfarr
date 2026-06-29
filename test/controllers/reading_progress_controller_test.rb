# frozen_string_literal: true

require "test_helper"

class ReadingProgressControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @other = users(:two)
    @book = books(:audiobook_acquired)
    sign_in_as(@user)
  end

  test "show returns empty json when there is no progress" do
    get progress_library_path(@book)
    assert_response :success
    assert_equal({}, JSON.parse(response.body))
  end

  test "update upserts progress for the current user" do
    put progress_library_path(@book), params: { location: "epubcfi(/6/4)", percent: 42 }
    assert_response :no_content

    rp = @user.reading_progresses.find_by(book: @book)
    assert_equal "epubcfi(/6/4)", rp.location
    assert_in_delta 42, rp.percent, 0.001

    # a second update overwrites rather than duplicating
    put progress_library_path(@book), params: { location: "epubcfi(/6/8)", percent: 55 }
    assert_response :no_content
    assert_equal 1, @user.reading_progresses.where(book: @book).count
    assert_equal "epubcfi(/6/8)", @user.reading_progresses.find_by(book: @book).location
  end

  test "update clamps percent into 0..100" do
    put progress_library_path(@book), params: { location: "x", percent: 999 }
    assert_response :no_content
    assert_in_delta 100, @user.reading_progresses.find_by(book: @book).percent, 0.001
  end

  test "progress is isolated per user" do
    ReadingProgress.create!(user: @other, book: @book, location: "other", percent: 90)

    get progress_library_path(@book)
    assert_response :success
    assert_equal({}, JSON.parse(response.body))
  end

  test "requires authentication" do
    sign_out
    get progress_library_path(@book)
    assert_response :redirect
  end
end
