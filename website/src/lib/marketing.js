export function initMarketing(root) {
  var cleanups = []
  root.querySelectorAll('[data-choice-group]').forEach(function (group) {
    var tabs = group.querySelector('[data-choice-tabs]')
    var buttons = Array.from(tabs.querySelectorAll('button'))
    var panels = Array.from(group.querySelectorAll('[data-choice-panel]'))
    tabs.hidden = false
    tabs.setAttribute('role', 'tablist')
    function select(index, focus) {
      buttons.forEach(function (button, i) {
        button.setAttribute('role', 'tab')
        button.setAttribute('aria-selected', String(i === index))
        button.tabIndex = i === index ? 0 : -1
        panels[i].hidden = i !== index
        panels[i].setAttribute('role', 'tabpanel')
        panels[i].setAttribute('aria-labelledby', button.id)
        panels[i].tabIndex = 0
      })
      if (focus) buttons[index].focus()
    }
    var onClick = function (event) {
      var button = event.target.closest('button')
      var index = buttons.indexOf(button)
      if (index >= 0) select(index, false)
    }
    var onKey = function (event) {
      var index = buttons.indexOf(event.target)
      if (index < 0) return
      var next = index
      if (event.key === 'ArrowRight' || event.key === 'ArrowDown') next = (index + 1) % buttons.length
      else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') next = (index - 1 + buttons.length) % buttons.length
      else if (event.key === 'Home') next = 0
      else if (event.key === 'End') next = buttons.length - 1
      else return
      event.preventDefault()
      select(next, true)
    }
    tabs.addEventListener('click', onClick)
    tabs.addEventListener('keydown', onKey)
    select(0, false)
    cleanups.push(function () {
      tabs.removeEventListener('click', onClick)
      tabs.removeEventListener('keydown', onKey)
      tabs.hidden = true
      panels.forEach(function (panel) { panel.hidden = false; panel.removeAttribute('role'); panel.removeAttribute('aria-labelledby'); panel.removeAttribute('tabindex') })
    })
  })
  var faqButtons = Array.from(root.querySelectorAll('[data-faq-toggle]'))
  if (faqButtons.length) {
    var setFaq = function (button, expanded) {
      button.setAttribute('aria-expanded', String(expanded))
      button.ownerDocument.getElementById(button.getAttribute('aria-controls')).hidden = !expanded
    }
    var onFaqClick = function (event) {
      setFaq(event.currentTarget, event.currentTarget.getAttribute('aria-expanded') !== 'true')
    }
    var onFaqKey = function (event) {
      var index = faqButtons.indexOf(event.currentTarget)
      var next
      if (event.key === 'ArrowDown') next = (index + 1) % faqButtons.length
      else if (event.key === 'ArrowUp') next = (index - 1 + faqButtons.length) % faqButtons.length
      else if (event.key === 'Home') next = 0
      else if (event.key === 'End') next = faqButtons.length - 1
      else return
      event.preventDefault()
      faqButtons[next].focus()
    }
    faqButtons.forEach(function (button) {
      setFaq(button, false)
      button.addEventListener('click', onFaqClick)
      button.addEventListener('keydown', onFaqKey)
    })
    cleanups.push(function () {
      faqButtons.forEach(function (button) {
        button.removeEventListener('click', onFaqClick)
        button.removeEventListener('keydown', onFaqKey)
        setFaq(button, true)
      })
    })
  }
  var menu = root.querySelector('.mobile-menu')
  if (menu) {
    var closeMenu = function (event) {
      if (event.type === 'click' && event.target.closest('a')) menu.open = false
      if (event.key === 'Escape' && menu.open) { event.preventDefault(); menu.open = false; menu.querySelector('summary').focus() }
    }
    menu.addEventListener('click', closeMenu)
    menu.addEventListener('keydown', closeMenu)
    cleanups.push(function () { menu.removeEventListener('click', closeMenu); menu.removeEventListener('keydown', closeMenu) })
  }
  if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches && 'IntersectionObserver' in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return
        entry.target.classList.add('entered')
        observer.unobserve(entry.target)
      })
    }, { threshold: 0.12 })
    root.querySelectorAll('.section-heading > *, .feature-copy > *, .product-shot, .evidence-row, .hero-title, .hero-description').forEach(function (el) { observer.observe(el) })
    cleanups.push(function () { observer.disconnect() })
  }
  return function () { cleanups.forEach(function (cleanup) { cleanup() }) }
}
