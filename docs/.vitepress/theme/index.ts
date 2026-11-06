import DefaultTheme from 'vitepress/theme'
import type { Theme } from 'vitepress'
import { enableImageZoom } from './image-zoom'
import './custom.css'
import './image-zoom.css'

export default {
  extends: DefaultTheme,
  enhanceApp() {
    // Images on a page open full screen with zoom and scroll. Linked images keep their link.
    enableImageZoom('.vp-doc img')
  }
} satisfies Theme
