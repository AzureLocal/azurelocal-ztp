// Click an image on a page to open it full screen, as wide as the window.
// Zoom: mouse wheel (at the cursor), the + and - buttons or keys. Double-click: actual size, or the whole image.
// Move: drag, scroll bars, arrow keys.
// Fit: the Fit button or 0. Actual size: 1. Close: the close button or Esc.
// No dependencies. One delegated click listener, so it works across client-side page changes.

const MAX_SCALE = 8

export function enableImageZoom(selector: string): void {
  if (typeof document === 'undefined') return
  const w = window as unknown as { __imageZoom?: boolean }
  if (w.__imageZoom) return
  w.__imageZoom = true

  document.addEventListener('click', (event) => {
    const target = event.target
    if (!(target instanceof HTMLImageElement) || !target.matches(selector) || target.closest('a')) return
    event.preventDefault()
    openViewer(target)
  })
}

function button(label: string, title: string): HTMLButtonElement {
  const b = document.createElement('button')
  b.type = 'button'
  b.className = 'iz-button'
  b.textContent = label
  b.title = title
  b.setAttribute('aria-label', title)
  return b
}

function openViewer(source: HTMLImageElement): void {
  const previousFocus = document.activeElement as HTMLElement | null
  const previousOverflow = document.documentElement.style.overflow

  const overlay = document.createElement('div')
  overlay.className = 'iz-overlay'
  overlay.setAttribute('role', 'dialog')
  overlay.setAttribute('aria-modal', 'true')
  overlay.setAttribute('aria-label', source.alt || 'Image')

  const toolbar = document.createElement('div')
  toolbar.className = 'iz-toolbar'
  const hint = document.createElement('span')
  hint.className = 'iz-hint'
  hint.textContent = 'Wheel or + / − to zoom · drag or scroll to move · Esc to close'
  const level = document.createElement('span')
  level.className = 'iz-level'
  const zoomOut = button('−', 'Zoom out (-)')
  const fitButton = button('Fit', 'Fit to window (0)')
  const actual = button('100%', 'Actual size (1)')
  const zoomIn = button('+', 'Zoom in (+)')
  const original = document.createElement('a')
  original.className = 'iz-button'
  original.href = source.currentSrc || source.src
  original.target = '_blank'
  original.rel = 'noopener'
  original.textContent = 'Open'
  original.title = 'Open the image in a new tab'
  const close = button('×', 'Close (Esc)')
  toolbar.append(hint, level, zoomOut, fitButton, actual, zoomIn, original, close)

  const stage = document.createElement('div')
  stage.className = 'iz-stage'
  stage.tabIndex = -1

  const img = new Image()
  img.className = 'iz-img'
  img.alt = source.alt
  img.draggable = false
  img.src = source.currentSrc || source.src
  stage.append(img)

  overlay.append(toolbar, stage)
  document.body.append(overlay)
  document.documentElement.style.overflow = 'hidden'
  stage.focus()

  let scale = 1
  let fit = 1
  // How the scale follows a window resize: the whole image, the window width, or none once you zoom.
  let mode: 'page' | 'width' | null = 'width'

  const naturalWidth = () => img.naturalWidth || source.naturalWidth || 1
  const naturalHeight = () => img.naturalHeight || source.naturalHeight || 1
  const computeFit = () => Math.min(stage.clientWidth / naturalWidth(), stage.clientHeight / naturalHeight())
  const computeWidth = () => Math.min(stage.clientWidth / naturalWidth(), 1)

  // Set the scale, keeping the image point under (x, y) where it is. Defaults to the centre of the stage.
  function setScale(next: number, x?: number, y?: number): void {
    const min = Math.min(fit, 1) / 2
    next = Math.max(min, Math.min(MAX_SCALE, next))
    const box = stage.getBoundingClientRect()
    const cx = x ?? box.left + stage.clientWidth / 2
    const cy = y ?? box.top + stage.clientHeight / 2
    const before = img.getBoundingClientRect()
    const ix = (cx - before.left) / scale
    const iy = (cy - before.top) / scale
    scale = next
    img.style.width = `${naturalWidth() * scale}px`
    img.style.height = `${naturalHeight() * scale}px`
    const after = img.getBoundingClientRect()
    stage.scrollLeft += after.left + ix * scale - cx
    stage.scrollTop += after.top + iy * scale - cy
    level.textContent = `${Math.round(scale * 100)}%`
  }

  // The whole image in the window.
  function toFit(): void {
    fit = computeFit()
    mode = 'page'
    setScale(fit)
  }

  // Opening view: as wide as the window (never above actual size), from the top. A tall diagram stays readable and
  // scrolls down.
  function toWidth(): void {
    fit = computeFit()
    mode = 'width'
    setScale(computeWidth())
    // A vertical scroll bar that appears takes width; fit again so there's no sideways scroll.
    if (stage.scrollWidth > stage.clientWidth) setScale(computeWidth())
    stage.scrollLeft = 0
    stage.scrollTop = 0
  }

  if (img.complete && img.naturalWidth) toWidth()
  else img.addEventListener('load', toWidth, { once: true })

  const step = 1.25
  const zoomBy = (factor: number, x?: number, y?: number) => { mode = null; setScale(scale * factor, x, y) }
  zoomIn.addEventListener('click', () => zoomBy(step))
  zoomOut.addEventListener('click', () => zoomBy(1 / step))
  fitButton.addEventListener('click', toFit)
  actual.addEventListener('click', () => { mode = null; setScale(1) })

  stage.addEventListener('wheel', (event) => {
    event.preventDefault()
    zoomBy(Math.exp(-event.deltaY * 0.0015), event.clientX, event.clientY)
  }, { passive: false })

  stage.addEventListener('dblclick', (event) => {
    const near = Math.abs(scale - 1) < 0.05
    mode = null
    setScale(near ? computeFit() : 1, event.clientX, event.clientY)
  })

  // Drag to move with a mouse or pen. Touch keeps the browser's own scrolling.
  let drag: { x: number; y: number; left: number; top: number } | null = null
  stage.addEventListener('pointerdown', (event) => {
    if (event.pointerType === 'touch' || event.button !== 0) return
    // Leave a press on a scroll bar to the scroll bar.
    const box = stage.getBoundingClientRect()
    if (event.clientX - box.left >= stage.clientWidth || event.clientY - box.top >= stage.clientHeight) return
    drag = { x: event.clientX, y: event.clientY, left: stage.scrollLeft, top: stage.scrollTop }
    stage.setPointerCapture(event.pointerId)
    stage.classList.add('iz-dragging')
  })
  stage.addEventListener('pointermove', (event) => {
    if (!drag) return
    stage.scrollLeft = drag.left - (event.clientX - drag.x)
    stage.scrollTop = drag.top - (event.clientY - drag.y)
  })
  const endDrag = () => { drag = null; stage.classList.remove('iz-dragging') }
  stage.addEventListener('pointerup', endDrag)
  stage.addEventListener('pointercancel', endDrag)

  const onResize = () => {
    if (mode === 'page') toFit()
    else if (mode === 'width') { fit = computeFit(); setScale(computeWidth()) }
    else fit = computeFit()
  }
  window.addEventListener('resize', onResize)

  function onKey(event: KeyboardEvent): void {
    if (event.key === 'Escape') { event.preventDefault(); closeViewer() }
    else if (event.key === '+' || event.key === '=') zoomBy(step)
    else if (event.key === '-' || event.key === '_') zoomBy(1 / step)
    else if (event.key === '0') toFit()
    else if (event.key === '1') { mode = null; setScale(1) }
  }
  document.addEventListener('keydown', onKey)

  function closeViewer(): void {
    document.removeEventListener('keydown', onKey)
    window.removeEventListener('resize', onResize)
    overlay.remove()
    document.documentElement.style.overflow = previousOverflow
    previousFocus?.focus?.()
  }
  close.addEventListener('click', closeViewer)
}
