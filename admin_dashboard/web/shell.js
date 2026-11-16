(function () {
  var loading = document.getElementById('dso-loading');
  var slow = document.getElementById('dso-loading-slow');
  var slowTimer = window.setTimeout(function () {
    if (slow) {
      slow.textContent =
        'Still loading. This can take a minute on a slow connection.';
    }
  }, 10000);

  window.addEventListener('flutter-first-frame', function () {
    window.clearTimeout(slowTimer);
    if (!loading) return;
    loading.classList.add('dso-loading-hidden');
    window.setTimeout(function () {
      if (loading && loading.parentNode) {
        loading.parentNode.removeChild(loading);
      }
    }, 260);
  });
})();

(function () {
  var viewport = window.visualViewport;
  function allowZoom() {
    var meta = document.querySelector('meta[name="viewport"][flt-viewport]');
    if (!meta || meta.content.indexOf('user-scalable=no') === -1) return;
    meta.content = 'width=device-width, initial-scale=1.0';
    document.body.style.touchAction = 'pinch-zoom';
  }
  function followZoom() {
    var view = document.querySelector('flutter-view');
    if (!view) return;
    view.style.transform =
      'translate(' + viewport.offsetLeft + 'px, ' + viewport.offsetTop + 'px)';
  }
  new MutationObserver(allowZoom).observe(document.head, { childList: true });
  if (viewport) {
    viewport.addEventListener('resize', followZoom);
    viewport.addEventListener('scroll', followZoom);
  }
})();
