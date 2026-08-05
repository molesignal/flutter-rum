import 'sanitization.dart';

String sanitizeUrl(String raw, bool includeQueryString) {
  final String value = raw.trim();
  final Uri? parsed = Uri.tryParse(value);
  if (parsed != null && parsed.hasAuthority) {
    return sanitizeUrlValue(value, includeQuery: includeQueryString);
  }
  String result = sanitizeText(value);
  final int fragment = result.indexOf('#');
  if (fragment >= 0) result = result.substring(0, fragment);
  if (!includeQueryString) {
    final int query = result.indexOf('?');
    if (query >= 0) result = result.substring(0, query);
  }
  return result;
}

String pagePath(String url) {
  final Uri? parsed = Uri.tryParse(url);
  if (parsed == null) return url;
  final String path = parsed.path.isEmpty ? url : parsed.path;
  return parsed.hasQuery ? '$path?${parsed.query}' : path;
}

bool matchesUrl(String url, List<Pattern> matchers) {
  for (final Pattern matcher in matchers) {
    try {
      if (url.contains(matcher)) return true;
    } on Object {
      // A user-provided pattern must not affect application traffic.
    }
  }
  return false;
}
