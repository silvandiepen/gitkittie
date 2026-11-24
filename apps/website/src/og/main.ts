import '@/styles/main.scss'
import { createApp, nextTick } from 'vue'
import ShareCard from './ShareCard.vue'
import { shareCard, shareCards } from './cards'

/**
 * Entry of `og.html`. Without `?path=` it only lists the cards to make; with one it draws
 * that card and resolves `window.__shareCardReady` once the fonts and the screenshot are in,
 * so the capture never catches a half-drawn card.
 */
declare global {
  interface Window {
    __shareCards: ReturnType<typeof shareCards>
    __shareCardReady: Promise<void>
  }
}

window.__shareCards = shareCards()

const path = new URLSearchParams(location.search).get('path')
window.__shareCardReady = (async () => {
  if (path === null) return
  createApp(ShareCard, { card: shareCard(path) }).mount('#card')
  await nextTick()
  await document.fonts.ready
  await Promise.all([...document.images].map((image) => image.decode().catch(() => undefined)))
})()
