# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@rails/actioncable", to: "actioncable.esm.js"
pin "@rails/actioncable/src", to: "actioncable.esm.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

# Reader libraries (ponytail: CDN pins; vendor into vendor/javascript for offline use)
pin "epubjs", to: "https://cdn.jsdelivr.net/npm/epubjs@0.3.93/+esm"
pin "pdfjs-dist", to: "https://cdn.jsdelivr.net/npm/pdfjs-dist@4.7.76/+esm"
pin "libarchive.js", to: "https://cdn.jsdelivr.net/npm/libarchive.js@1.3.0/main.js"
