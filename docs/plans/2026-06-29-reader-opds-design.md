# In-browser Reader + Reading Progress + OPDS — design

Date: 2026-06-29. Branch: `feature/libgen-discovery`. Status: approved, implementing.

## Goal

Give Shelfarr a Calibre-Web/BookLore-style in-browser reader for the books it
already tracks, remember each user's place, and expose an OPDS feed so external
readers (Boox, KOReader) can browse and download the library. This is the PR #2
roadmap item; it moves Shelfarr toward replacing BookLore + Calibre-Web.

## Scope (decided)

- **Formats:** EPUB (epub.js), PDF (pdf.js), comics CBZ/CBR (JSZip + image viewer).
- **Progress:** per-user, per-book saved position, restored on open.
- **OPDS:** OPDS 1.2 Atom catalog (root nav + "All books" acquisition feed), HTTP Basic auth.
- **Library source:** books Shelfarr tracks (`Book.acquired`, i.e. `file_path` present). No directory scanning of arbitrary files — out of scope.

## Architecture

Books live on disk; `Book.file_path` is the download destination (a directory,
sometimes a file). No ActiveStorage. The reader serves bytes straight from disk.

```
Browser (Stimulus reader_controller)        Rails
  ├─ epub.js / pdf.js / cbz viewer  ──GET──▶ library#file  ──send_file(Range)──▶ /ebooks file
  ├─ restore location on open       ──GET──▶ reading_progress#show
  └─ save location (debounced ~2s)  ──PUT──▶ reading_progress#update
External reader (Boox/KOReader)     ──────▶ opds/catalog (Atom, HTTP Basic) ──▶ acquisition links → library#file
```

### Backend pieces

1. **`Book#primary_file` / `Book#reader_format`** (the one bit of real logic → unit-tested)
   - `primary_file`: if `file_path` is a file, use it; if a directory, pick the largest file whose
     extension is in the reader set (`.epub .pdf .cbz .cbr`). Returns `nil` if none.
   - `reader_format`: maps the primary file's extension → `:epub | :pdf | :comic | nil`.
   - `readable?`: `reader_format.present?` (only ebooks; audiobooks excluded).

2. **`LibraryController#read`** — full-screen reader view; sets `@book`, format, file/progress URLs.
   **`LibraryController#file`** — `send_file(primary_file, disposition: "inline")`, Range-enabled.
   Security: 404 unless `Book.acquired`, and `primary_file` must resolve **inside**
   `path_within_allowed_directories?` (reuse existing helper). Never accepts a path param.

3. **`ReadingProgress`** model — `belongs_to :user, :book`; columns `location:string`
   (epub CFI / pdf page / comic page index), `percent:float`, timestamps; unique index `[user_id, book_id]`.
   `ReadingProgressController#show` (JSON) / `#update` (upsert for Current.user + book).

4. **`Opds::CatalogController`** — `allow_unauthenticated_access`, HTTP Basic via
   `authenticate_with_http_basic { |u,p| User.active.find_by(username: u)&.authenticate(p) }`.
   - `root` → nav feed linking to the acquisition feed.
   - `books` → acquisition feed of `Book.acquired.ebooks`; each entry has an
     `http://opds-spec.org/acquisition` link to `library#file` + cover.
   Atom XML built with a jbuilder/erb `.atom.builder` template. `# ponytail: basic auth, fine on LAN; token auth if exposed`.

### Frontend

- Pin `jszip`, `epubjs`, `pdfjs-dist` in `config/importmap.rb` (CDN ESM; bin/importmap shebang is CRLF, edit the file directly).
- `reader_controller.js` (Stimulus): reads `data-reader-format`, `data-file-url`,
  `data-progress-url` from the container; lazy-imports the right viewer; restores
  saved location; on relocate/page-change debounces a `PUT` to the progress URL.
- A **"Read"** button on `library/show` for `@book.readable?`, linking to `read_library_path`.
- Reader view uses a minimal full-bleed layout (no app chrome) for reading space.

## Routes

```ruby
resources :library, only: [...] do
  member do
    get :read
    get :file
    get  "progress", to: "reading_progress#show"
    put  "progress", to: "reading_progress#update"
  end
end
namespace :opds do
  get "/",      to: "catalog#root"
  get "books",  to: "catalog#books"
end
```

## Phasing (a commit each)

1. **Plumbing** — `primary_file`/`reader_format` (+ model test), `library#file` (+ controller test).
2. **EPUB + progress** — epub.js viewer, `ReadingProgress` model/migration/endpoints, Read button, restore/save (+ tests).
3. **PDF + comics** — pdf.js + CBZ/CBR viewers on the same progress contract (+ integration test per format).
4. **OPDS** — catalog controller + Atom templates + HTTP Basic (+ controller test: auth required, valid feed, only acquired books).

## Testing

Run in the documented ruby container. Model unit tests for `primary_file`/`reader_format`
(file vs dir, extension precedence, missing). Controller tests for `#file` (auth, bytes,
404, path stays inside allowed dirs), `reading_progress` (per-user isolation, upsert),
`opds` (Basic auth required, Atom validity, lists only acquired ebooks). One integration
test that `#read` renders the correct viewer container + data URLs per format. JS stays
thin glue → covered by the integration test.

## Security ceilings (not simplified away)

- `#file` resolves only via `Book#primary_file` within allowed dirs — no path params, no traversal.
- OPDS HTTP Basic over LAN; bypasses 2FA by design for reader compatibility. Token/HTTPS if ever exposed.
