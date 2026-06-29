# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@rails/actioncable", to: "actioncable.esm.js"
pin "@rails/actioncable/src", to: "actioncable.esm.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

# Reader libraries via esm.sh, which resolves transitive deps + CORS correctly
# (jsdelivr's +esm bundle of epub.js breaks on the es5-ext dep).
# ponytail: CDN pins; vendor into vendor/javascript for offline use.
pin "epubjs", to: "https://esm.sh/epubjs@0.3.93"
pin "pdfjs-dist", to: "https://esm.sh/pdfjs-dist@4.7.76"
pin "libarchive.js", to: "https://esm.sh/libarchive.js@1.3.0"
