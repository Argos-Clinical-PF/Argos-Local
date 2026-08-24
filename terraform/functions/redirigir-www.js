// CloudFront Function (viewer-request): canonicaliza el host.
//
// La distribución sirve el apex y `www` con el mismo origen, y no reenvía el Host del viewer
// (política AllViewerExceptHostHeader), así que el backend no puede distinguirlos: contesta
// siempre con Access-Control-Allow-Origin del apex. Una visita por `www` cargaba la página pero
// fallaba en la primera llamada a la API por CORS, sin error visible más que un fallo opaco.
//
// Redirigir en el borde deja un único origen para CORS, la sesión y las URLs absolutas.
function handler(event) {
  var request = event.request;
  var host = request.headers.host && request.headers.host.value;

  if (!host || host.indexOf('www.') !== 0) {
    return request;
  }

  var destino = 'https://' + host.slice(4) + request.uri;
  var qs = [];
  for (var clave in request.querystring) {
    var valor = request.querystring[clave];
    qs.push(valor.value ? clave + '=' + valor.value : clave);
  }
  if (qs.length) {
    destino += '?' + qs.join('&');
  }

  return {
    statusCode: 301,
    statusDescription: 'Moved Permanently',
    headers: { location: { value: destino } },
  };
}
