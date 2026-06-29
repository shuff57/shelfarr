import { Controller } from "@hotwired/stimulus"

// Drives the in-browser reader. Dispatches by format to the matching viewer,
// restores the saved reading position on open, and saves it (debounced) as the
// reader moves. EPUB is handled here; PDF and comics are added in phase 3.
export default class extends Controller {
  static values = { format: String, fileUrl: String, progressUrl: String }
  static targets = ["viewport", "prev", "next", "percent", "status"]

  connect() {
    this.saveTimer = null
    switch (this.formatValue) {
      case "epub":
        this.setupEpub()
        break
      default:
        this.showStatus(`No viewer available for "${this.formatValue}" yet.`)
    }
  }

  disconnect() {
    clearTimeout(this.saveTimer)
    if (this.keyHandler) document.removeEventListener("keyup", this.keyHandler)
    if (this.book && this.book.destroy) this.book.destroy()
  }

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

    // Locations enable a percent read-out and are needed for the progress bar.
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

    this.keyHandler = (event) => {
      if (event.key === "ArrowLeft") this.prev()
      if (event.key === "ArrowRight") this.next()
    }
    document.addEventListener("keyup", this.keyHandler)
  }

  prev() {
    if (this.rendition) this.rendition.prev()
  }

  next() {
    if (this.rendition) this.rendition.next()
  }

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
