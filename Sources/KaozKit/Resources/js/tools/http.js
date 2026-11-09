// Shared HTTP helper for JS tools, over the native XMLHttpRequest shim.
import "../xmlhttprequest.js"; // installs globalThis.XMLHttpRequest (needs native __http)

// GET `url` with optional headers. Resolves { status, text, contentType,
// location }; rejects on a network (transport) error. `options.sameSite`:
// a redirect to another site is not followed, its 3xx comes back.
// `options.publicOnly`: the page is given only if every connection made
// reached an internet address, never one of the local network.
export function httpGet(url, headers, options) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("GET", url);
    xhr.sameSiteRedirectsOnly = Boolean(options && options.sameSite);
    xhr.publicAddressesOnly = Boolean(options && options.publicOnly);
    const h = headers || {};
    for (const k of Object.keys(h)) xhr.setRequestHeader(k, h[k]);
    xhr.onload = () => resolve({
      status: xhr.status,
      text: xhr.responseText,
      contentType: (xhr.getResponseHeader("content-type") || "").toLowerCase(),
      location: xhr.getResponseHeader("location"),
    });
    xhr.onerror = (e) => reject(new Error("network error: " + e));
    xhr.send(null);
  });
}
