fetch('/api/data')
  .then(function(r) { return r.json(); })
  .then(function(items) {
    var el = document.getElementById('data');
    el.innerHTML = '<h2>API Data</h2><ul>' +
      items.map(function(i) { return '<li>' + i.title + '</li>'; }).join('') +
      '</ul>';
  })
  .catch(function(e) { console.error('API error:', e); });
