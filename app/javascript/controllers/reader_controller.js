import { Controller } from "@hotwired/stimulus"

const PDF_VERSION = "4.7.76"
const PDF_WORKER = `https://cdn.jsdelivr.net/npm/pdfjs-dist@${PDF_VERSION}/build/pdf.worker.min.mjs`
const LIBARCHIVE_WORKER = "https://cdn.jsdelivr.net/npm/libarchive.js@1.3.0/dist/worker-bundle.js"

// Drives the in-browser reader. Dispatches by format to the matching viewer,
// restores the saved reading position on open, and saves it (debounced) as the
// reader moves. The saved "location" is opaque per format: an epub CFI, a pdf
// page number, or a comic page index.
export default class extends Controller {
  static values = { format: String, fileUrl: String, progressUrl: String }
  static targets = ["viewport", "prev", "next", "percent", "status"]

  connect() {
    this.saveTimer = null
    const setup = {
      epub: () => this.setupEpub(),
      pdf: () => this.setupPdf(),
      comic: () => this.setupComic()
    }[this.formatValue]

    if (setup) {
      setup().catch((error) => this.showStatus(`Could not open this book: ${error.message}`))
    } else {
      this.showStatus(`No viewer available for "${this.formatValue}".`)
    }
  }

  disconnect() {
    clearTimeout(this.saveTimer)
    if (this.keyHandler) document.removeEventListener("keyup", this.keyHandler)
    if (this.book && this.book.destroy) this.book.destroy()
    if (this.pdf && this.pdf.destroy) this.pdf.destroy()
    if (this.comicPages) this.comicPages.forEach((url) => URL.revokeObjectURL(url))
  }

  // ---- EPUB (epub.js) ----

  async setupEpub() {
    const { default: ePub } = await import("epubjs")
    this.book = ePub(this.fileUrlValue)
    this.rendition = this.book.renderTo(this.viewportTarget, {
      width: "100%",
      height: "100%",
      flow: "paginated",
      spread: "auto"
    })

    const saved = await this.loadProgress()
    await this.rendition.display(saved.location || undefined)

    this.book.ready
      .then(() => this.book.locations.generate(1600))
      .then(() => { if (saved.percent != null) this.updatePercent(saved.percent) })
      .catch(() => {})

    this.rendition.on("relocated", (location) => {
      const cfi = location.start.cfi
      let percent = 0
      try {
        percent = Math.round((this.book.locations.percentageFromCfi(cfi) || 0) * 100)
      } catch (_) { /* locations not ready yet */ }
      this.updatePercent(percent)
      this.queueSave(cfi, percent)
    })

    this.bindKeys()
  }

  // ---- PDF (pdf.js) ----

  async setupPdf() {
    const pdfjs = await import("pdfjs-dist")
    pdfjs.GlobalWorkerOptions.workerSrc = PDF_WORKER

    this.pdf = await pdfjs.getDocument(this.fileUrlValue).promise
    this.canvas = document.createElement("canvas")
    this.canvas.className = "mx-auto block"
    this.viewportTarget.appendChild(this.canvas)

    const saved = await this.loadProgress()
    const startPage = parseInt(saved.location, 10)
    this.page = clamp(Number.isNaN(startPage) ? 1 : startPage, 1, this.pdf.numPages)

    await this.renderPdfPage()
    this.bindKeys()
  }

  async renderPdfPage() {
    const page = await this.pdf.getPage(this.page)
    const targetWidth = this.viewportTarget.clientWidth || 800
    const base = page.getViewport({ scale: 1 })
    const viewport = page.getViewport({ scale: targetWidth / base.width })

    this.canvas.width = viewport.width
    this.canvas.height = viewport.height
    await page.render({ canvasContext: this.canvas.getContext("2d"), viewport }).promise

    const percent = Math.round((this.page / this.pdf.numPages) * 100)
    this.updatePercent(percent)
    this.queueSave(String(this.page), percent)
  }

  // ---- Comics (CBZ/CBR via libarchive.js) ----

  async setupComic() {
    const { Archive } = await import("libarchive.js")
    Archive.init({ workerUrl: LIBARCHIVE_WORKER })

    const blob = await fetch(this.fileUrlValue).then((r) => r.blob())
    const archive = await Archive.open(blob)
    const tree = await archive.extractFiles()

    const images = []
    collectImages(tree, "", images)
    images.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }))
    this.comicPages = images.map((entry) => URL.createObjectURL(entry.file))

    if (this.comicPages.length === 0) {
      this.showStatus("No images found in this comic archive.")
      return
    }

    this.image = document.createElement("img")
    this.image.className = "mx-auto block max-h-full"
    this.viewportTarget.appendChild(this.image)

    const saved = await this.loadProgress()
    const startIndex = parseInt(saved.location, 10)
    this.showComicPage(Number.isNaN(startIndex) ? 0 : startIndex)
    this.bindKeys()
  }

  showComicPage(index) {
    this.comicIndex = clamp(index, 0, this.comicPages.length - 1)
    this.image.src = this.comicPages[this.comicIndex]

    const percent = Math.round(((this.comicIndex + 1) / this.comicPages.length) * 100)
    this.updatePercent(percent)
    this.queueSave(String(this.comicIndex), percent)
  }

  // ---- Navigation (dispatches by active viewer) ----

  prev() {
    if (this.rendition) this.rendition.prev()
    else if (this.pdf) { this.page = clamp(this.page - 1, 1, this.pdf.numPages); this.renderPdfPage() }
    else if (this.comicPages) this.showComicPage(this.comicIndex - 1)
  }

  next() {
    if (this.rendition) this.rendition.next()
    else if (this.pdf) { this.page = clamp(this.page + 1, 1, this.pdf.numPages); this.renderPdfPage() }
    else if (this.comicPages) this.showComicPage(this.comicIndex + 1)
  }

  bindKeys() {
    this.keyHandler = (event) => {
      if (event.key === "ArrowLeft") this.prev()
      if (event.key === "ArrowRight") this.next()
    }
    document.addEventListener("keyup", this.keyHandler)
  }

  // ---- Shared UI + progress ----

  updatePercent(percent) {
    if (this.hasPercentTarget) this.percentTarget.textContent = `${percent}%`
  }

  showStatus(message) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message
    this.statusTarget.classList.remove("hidden")
  }

  async loadProgress() {
    try {
      const res = await fetch(this.progressUrlValue, { headers: { Accept: "application/json" } })
      return res.ok ? await res.json() : {}
    } catch (_) {
      return {}
    }
  }

  queueSave(location, percent) {
    clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => this.saveProgress(location, percent), 2000)
  }

  saveProgress(location, percent) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.progressUrlValue, {
      method: "PUT",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": token || "" },
      body: JSON.stringify({ location, percent })
    }).catch(() => {})
  }
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max)
}

// libarchive.js returns a nested {name: File | subtree} object; collect image files.
function collectImages(tree, prefix, out) {
  for (const [name, value] of Object.entries(tree)) {
    if (value instanceof File) {
      if (/\.(jpe?g|png|gif|webp)$/i.test(name)) out.push({ name: prefix + name, file: value })
    } else if (value && typeof value === "object") {
      collectImages(value, `${prefix}${name}/`, out)
    }
  }
}
