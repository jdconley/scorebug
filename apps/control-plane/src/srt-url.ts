/**
 * Serialize an SRT URL with literal ':' and '=' in query values.
 *
 * `URL.searchParams` form-encodes `streamid=publish:path` as `publish%3Apath`. FFmpeg 7+ decodes
 * SRT query values, but other SRT clients (Ubuntu 24.04's FFmpeg 6.1, OBS, Larix) pass them to
 * the server raw, which then rejects the stream ID. Everything else (`&`, `#`, `%`, spaces) stays
 * escaped, so `URL`/`URLSearchParams` still decode the same values.
 */
export function formatSrtUrl(url: URL): string {
  const result = new URL(url);
  result.search = [...url.searchParams]
    .map(
      ([key, value]) =>
        `${encodeURIComponent(key)}=${encodeURIComponent(value).replace(/%3A/g, ':').replace(/%3D/g, '=')}`,
    )
    .join('&');
  return result.toString();
}
