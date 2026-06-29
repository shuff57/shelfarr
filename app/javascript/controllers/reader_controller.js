import { Controller } from "@hotwired/stimulus"

const PDF_VERSION = "4.7.76"
const PDF_WORKER = `https://cdn.jsdelivr.net/npm/pdfjs-dist@${PDF_VERSION}/build/pdf.worker.min.mjs`
const IMAGE_RE = /\.(jpe?g|png|gif|webp|avif)$/i

const PREFS_KEY = "shelfarr.reader.prefs"
const DEFAULT_PREFS = { fontSize: 100, font: "serif", lineHeight: 1.6, margin: 8, theme: "dark", flow: "paginated" }
const FONTS = {
  serif: "Georgia, 'Times New Roman', serif",
  sans: "system-ui, -apple-system, Segoe UI, sans-serif",
  dyslexic: "'OpenDyslexic', 'Comic Sans MS', sans-serif"
}
const THEME_BG = { light: "#ffffff", sepia: "#f4ecd8", dark: "#0a0a0a" }

// Drives the in-browser reader with a BookLore/Calibre-style reading experience:
// tap-zones + immersive chrome, typography + theme controls, a table of contents,
// and a scrubbable progress bar. EPUB gets the full treatment; PDF and comics
// reuse the same progress/scrub UI with their own page renderers.
export default class extends Controller {
  static values = { format: String, fileUrl: String, progressUrl: String }
  static targets = [
    "viewport", "chrome", "chromeBottom", "epubControls", "toc", "tocList",
    "settings", "backdrop", "scrub", "percent", "chapter", "status",
    "fontSizeLabel", "lineHeight", "margin"
  ]

  connect() {
    this.saveTimer = null
    this.immersive = false
    this.prefs = this.loadPrefs()

    const setup = {
      epub: () => this.setupEpub(),
      pdf: () => this.setupPdf(),
      comic: () => this.setupComic()
    }[this.formatValue]

    if (this.formatValue !== "epub" && this.hasEpubControlsTarget) {
      this.epubControlsTarget.classList.add("hidden")
    }

    if (setup) {
      setup().catch((error) => this.showStatus(`Could not open this book: ${error.message}`))
    } else {
      this.showStatus(`No viewer available for "${this.formatValue}".`)
    }
  }

  disconnect() {
    clearTimeout(this.saveTimer)
    if (this.book && this.book.destroy) this.book.destroy()
    if (this.pdf && this.pdf.destroy) this.pdf.destroy()
    if (this.comicPages) this.comicPages.forEach((url) => URL.revokeObjectURL(url))
  }

  // ===== EPUB =====

  async setupEpub() {
    const { default: ePub } = await import("epubjs")
    // openAs: "epub" forces archive mode; without it epub.js treats the
    // extension-less /file URL as an unpacked directory and 404s on container.xml.
    this.book = ePub(this.fileUrlValue, { openAs: "epub" })
    this.rendition = this.book.renderTo(this.viewportTarget, {
      width: "100%", height: "100%", flow: this.prefs.flow, spread: "auto"
    })

    this.registerThemes()
    this.applyPrefs()

    // Click-to-page from inside the epub content (preserves text selection).
    this.rendition.hooks.content.register((contents) => {
      contents.document.documentElement.addEventListener("click", (e) => this.onContentClick(e, contents))
      contents.document.addEventListener("keyup", (e) => this.onKey(e))
    })

    const saved = await this.loadProgress()
    await this.rendition.display(saved.location || undefined)

    this.rendition.on("relocated", (loc) => this.onRelocated(loc))

    await this.book.ready
    await this.book.locations.generate(1600).catch(() => {})
    this.buildToc()
    this.onRelocated(this.rendition.currentLocation())
  }

  registerThemes() {
    this.rendition.themes.register("light", { body: { color: "#1a1a1a", background: "#ffffff" } })
    this.rendition.themes.register("sepia", { body: { color: "#5b4636", background: "#f4ecd8" } })
    this.rendition.themes.register("dark", { body: { color: "#cbd5e1", background: "#0a0a0a" }, a: { color: "#7dd3fc !important" } })
  }

  applyPrefs() {
    this.applyTheme(this.prefs.theme)
    this.rendition.themes.font(FONTS[this.prefs.font] || FONTS.serif)
    this.rendition.themes.fontSize(`${this.prefs.fontSize}%`)
    this.rendition.themes.override("line-height", String(this.prefs.lineHeight))
    this.applyMargin(this.prefs.margin)

    if (this.hasFontSizeLabelTarget) this.fontSizeLabelTarget.textContent = `${this.prefs.fontSize}%`
    if (this.hasLineHeightTarget) this.lineHeightTarget.value = this.prefs.lineHeight
    if (this.hasMarginTarget) this.marginTarget.value = this.prefs.margin
    this.markActive("theme", this.prefs.theme)
    this.markActive("font", this.prefs.font)
    this.markActive("flow", this.prefs.flow)
  }

  applyTheme(theme) {
    this.rendition.themes.select(theme)
    this.viewportTarget.style.background = THEME_BG[theme] || THEME_BG.dark
  }

  applyMargin(percent) {
    this.rendition.themes.override("padding-left", `${percent}%`)
    this.rendition.themes.override("padding-right", `${percent}%`)
  }

  buildToc() {
    const toc = this.book.navigation?.toc || []
    this.tocFlat = []
    const flatten = (items, depth) => items.forEach((it) => {
      this.tocFlat.push({ label: (it.label || "").trim(), href: it.href, depth })
      if (it.subitems && it.subitems.length) flatten(it.subitems, depth + 1)
    })
    flatten(toc, 0)

    if (!this.hasTocListTarget) return
    this.tocListTarget.innerHTML = ""
    this.tocFlat.forEach((it) => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "block w-full truncate rounded px-2 py-1.5 text-left text-gray-300 hover:bg-gray-800"
      btn.style.paddingLeft = `${0.5 + it.depth * 0.75}rem`
      btn.textContent = it.label || "—"
      btn.addEventListener("click", () => { this.rendition.display(it.href); this.toggleToc() })
      this.tocListTarget.appendChild(btn)
    })
  }

  chapterLabel(href) {
    if (!this.tocFlat || !href) return ""
    const base = href.split("#")[0]
    const match = this.tocFlat.find((i) => i.href && i.href.split("#")[0].endsWith(base.split("/").pop()))
    return match ? match.label : ""
  }

  onRelocated(loc) {
    if (!loc || !loc.start) return
    const cfi = loc.start.cfi
    let percent = 0
    try { percent = this.book.locations.percentageFromCfi(cfi) || 0 } catch (_) { /* not ready */ }
    this.updateProgressUI(percent, this.chapterLabel(loc.start.href))
    this.queueSave(cfi, Math.round(percent * 100))
  }

  // ===== Typography / theme controls (epub) =====

  fontLarger() { this.setFontSize(this.prefs.fontSize + 10) }
  fontSmaller() { this.setFontSize(this.prefs.fontSize - 10) }

  setFontSize(size) {
    this.prefs.fontSize = clamp(size, 70, 260)
    this.rendition.themes.fontSize(`${this.prefs.fontSize}%`)
    if (this.hasFontSizeLabelTarget) this.fontSizeLabelTarget.textContent = `${this.prefs.fontSize}%`
    this.savePrefs()
  }

  setFont(e) {
    this.prefs.font = e.currentTarget.dataset.font
    this.rendition.themes.font(FONTS[this.prefs.font] || FONTS.serif)
    this.markActive("font", this.prefs.font)
    this.savePrefs()
  }

  setLineHeight(e) {
    this.prefs.lineHeight = parseFloat(e.currentTarget.value)
    this.rendition.themes.override("line-height", String(this.prefs.lineHeight))
    this.savePrefs()
  }

  setMargin(e) {
    this.prefs.margin = parseInt(e.currentTarget.value, 10)
    this.applyMargin(this.prefs.margin)
    this.savePrefs()
  }

  setTheme(e) {
    this.prefs.theme = e.currentTarget.dataset.theme
    this.applyTheme(this.prefs.theme)
    this.markActive("theme", this.prefs.theme)
    this.savePrefs()
  }

  setFlow(e) {
    this.prefs.flow = e.currentTarget.dataset.flow
    this.rendition.flow(this.prefs.flow)
    this.markActive("flow", this.prefs.flow)
    this.savePrefs()
  }

  // ===== PDF =====

  async setupPdf() {
    const pdfjs = await import("pdfjs-dist")
    pdfjs.GlobalWorkerOptions.workerSrc = PDF_WORKER

    this.pdf = await pdfjs.getDocument(this.fileUrlValue).promise
    this.canvas = document.createElement("canvas")
    this.canvas.className = "mx-auto block"
    this.viewportTarget.classList.add("overflow-auto")
    this.viewportTarget.appendChild(this.canvas)

    const saved = await this.loadProgress()
    const startPage = parseInt(saved.location, 10)
    this.page = clamp(Number.isNaN(startPage) ? 1 : startPage, 1, this.pdf.numPages)
    await this.renderPdfPage()
  }

  async renderPdfPage() {
    const page = await this.pdf.getPage(this.page)
    const targetWidth = this.viewportTarget.clientWidth || 800
    const base = page.getViewport({ scale: 1 })
    const viewport = page.getViewport({ scale: targetWidth / base.width })

    this.canvas.width = viewport.width
    this.canvas.height = viewport.height
    await page.render({ canvasContext: this.canvas.getContext("2d"), viewport }).promise

    const percent = this.page / this.pdf.numPages
    this.updateProgressUI(percent, `Page ${this.page} / ${this.pdf.numPages}`)
    this.queueSave(String(this.page), Math.round(percent * 100))
  }

  // ===== Comics (CBZ/CBR) =====

  async setupComic() {
    // CBZ is a ZIP, handled in-JS by JSZip (no worker/wasm). CBR is RAR, which
    // JSZip can't read; we detect that and ask the user to convert.
    // ponytail: CBZ only; vendor an unrar/libarchive build for CBR support.
    const { default: JSZip } = await import("jszip")
    const buffer = await fetch(this.fileUrlValue).then((r) => r.arrayBuffer())

    let zip
    try {
      zip = await JSZip.loadAsync(buffer)
    } catch (_) {
      this.showStatus("This looks like a CBR (RAR) archive, which isn't supported yet — convert it to CBZ.")
      return
    }

    const entries = Object.values(zip.files)
      .filter((f) => !f.dir && IMAGE_RE.test(f.name))
      .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }))

    this.comicPages = []
    for (const entry of entries) {
      this.comicPages.push(URL.createObjectURL(await entry.async("blob")))
    }

    if (this.comicPages.length === 0) {
      this.showStatus("No images found in this comic archive.")
      return
    }

    this.image = document.createElement("img")
    this.image.className = "mx-auto block max-h-full"
    this.viewportTarget.classList.add("overflow-auto")
    this.viewportTarget.appendChild(this.image)

    const saved = await this.loadProgress()
    const startIndex = parseInt(saved.location, 10)
    this.showComicPage(Number.isNaN(startIndex) ? 0 : startIndex)
  }

  showComicPage(index) {
    this.comicIndex = clamp(index, 0, this.comicPages.length - 1)
    this.image.src = this.comicPages[this.comicIndex]
    const percent = (this.comicIndex + 1) / this.comicPages.length
    this.updateProgressUI(percent, `Page ${this.comicIndex + 1} / ${this.comicPages.length}`)
    this.queueSave(String(this.comicIndex), Math.round(percent * 100))
  }

  // ===== Navigation (dispatches by active viewer) =====

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

  scrub(e) {
    const fraction = parseInt(e.currentTarget.value, 10) / 1000
    if (this.book && this.book.locations && this.book.locations.length()) {
      const cfi = this.book.locations.cfiFromPercentage(fraction)
      if (cfi) this.rendition.display(cfi)
    } else if (this.pdf) {
      this.page = clamp(Math.round(fraction * this.pdf.numPages) || 1, 1, this.pdf.numPages)
      this.renderPdfPage()
    } else if (this.comicPages) {
      this.showComicPage(Math.round(fraction * (this.comicPages.length - 1)))
    }
  }

  onContentClick(e, contents) {
    if (e.target.closest && e.target.closest("a")) return
    const selection = contents.window.getSelection()
    if (selection && selection.toString().length > 0) return

    const width = contents.documentElement.clientWidth || contents.window.innerWidth
    if (e.clientX < width * 0.3) this.prev()
    else if (e.clientX > width * 0.7) this.next()
    else this.toggleChrome()
  }

  onKey(e) {
    if (e.target && e.target.matches && e.target.matches("input, textarea, select")) return
    if (e.key === "ArrowLeft") this.prev()
    else if (e.key === "ArrowRight" || e.key === " ") this.next()
    else if (e.key === "Escape") this.closePanels()
  }

  // ===== Chrome / panels =====

  toggleChrome() {
    this.immersive = !this.immersive
    this.chromeTarget.classList.toggle("-translate-y-full", this.immersive)
    if (this.hasChromeBottomTarget) this.chromeBottomTarget.classList.toggle("translate-y-full", this.immersive)
    this.closePanels()
  }

  toggleToc() { this.togglePanel(this.tocTarget) }
  toggleSettings() { this.togglePanel(this.settingsTarget) }

  togglePanel(panel) {
    const opening = panel.classList.contains("hidden")
    this.closePanels()
    if (opening) {
      panel.classList.remove("hidden")
      this.backdropTarget.classList.remove("hidden")
    }
  }

  closePanels() {
    if (this.hasTocTarget) this.tocTarget.classList.add("hidden")
    if (this.hasSettingsTarget) this.settingsTarget.classList.add("hidden")
    if (this.hasBackdropTarget) this.backdropTarget.classList.add("hidden")
  }

  // ===== Shared UI / progress =====

  updateProgressUI(fraction, chapterLabel) {
    const percent = Math.round((fraction || 0) * 100)
    if (this.hasPercentTarget) this.percentTarget.textContent = `${percent}%`
    if (this.hasScrubTarget) this.scrubTarget.value = Math.round((fraction || 0) * 1000)
    if (this.hasChapterTarget) this.chapterTarget.textContent = chapterLabel || ""
  }

  markActive(group, value) {
    this.element.querySelectorAll(`.reader-opt[data-${group}]`).forEach((btn) => {
      const on = btn.dataset[group] === value
      btn.classList.toggle("ring-2", on)
      btn.classList.toggle("ring-blue-500", on)
    })
  }

  showStatus(message) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message
    this.statusTarget.classList.remove("hidden")
    this.statusTarget.classList.add("grid")
  }

  // ===== Preferences (localStorage) + progress (server) =====
  // ponytail: display prefs are per-device; reading position syncs server-side.

  loadPrefs() {
    try {
      return { ...DEFAULT_PREFS, ...JSON.parse(localStorage.getItem(PREFS_KEY) || "{}") }
    } catch (_) {
      return { ...DEFAULT_PREFS }
    }
  }

  savePrefs() {
    try { localStorage.setItem(PREFS_KEY, JSON.stringify(this.prefs)) } catch (_) { /* ignore */ }
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
