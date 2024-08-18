import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';

final _log = Logger("Wiki");

/// Searches Wikipedia using the `opensearch` API for the most suitable page
/// (wikiTitle, null) or (null, errorMessage)
Future<(String?, String?)> findBestPage(String query) async {
  final response = await http
      .get(Uri.parse('https://en.wikipedia.org/w/api.php?action=opensearch&search=${const HtmlEscape().convert(query)}&limit=1&namespace=0&format=json'));

  if (response.statusCode == 200) {
    // If the server did return a 200 OK response,
    // then parse the JSON.
    try {
      var json = jsonDecode(response.body) as List<dynamic>;
      _log.fine(json);
      if ((json[1] as List).isNotEmpty) {
        return (json[1][0] as String, null);
      }
      else {
        return (null, 'Wikipedia entry not found: $query');
      }

    } catch (e) {
      _log.fine('error parsing JSON: $e');
      return (null, '$e');
    }
  } else {
    // If the server did not return a 200 OK response,
    // then throw an exception.
    return (null, 'Failed to load wiki result - Response: ${response.statusCode}');
  }
}

/// Returns the introduction in plain text for the Wikipedia page with the specified title
/// (WikiResult, null) or (null, errorMessage)
Future<(WikiResult?, String?)> fetchExtract(String title) async {
  final response = await http
      .get(Uri.parse('https://en.wikipedia.org/w/api.php?action=query&redirects&prop=extracts|pageimages&titles=${const HtmlEscape().convert(title)}&exintro=true&exsentences=2&explaintext=true&pithumbsize=240&format=json'));

  if (response.statusCode == 200) {
    // If the server did return a 200 OK response, then parse the JSON.
    _log.fine(jsonDecode(response.body));

    try {
      return (WikiResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>), null);

    } catch (e) {
      _log.fine('error parsing JSON: $e');
      return (null, 'Error: $e');
    }
  } else {
    // If the server did not return a 200 OK response,
      return (null, 'Error: ${response.statusCode}');
  }
}

/// Fetches the specified thumbnail as an image/image
/// (image, null) or (null, errorMessage)
Future<(img.Image?, String?)> fetchThumbnail(String uri) async {
  final response = await http.get(Uri.parse(uri));

  if (response.statusCode == 200) {
    // TODO check if image type is always the same, then provide decoder hint
    final image = img.decodeImage(response.bodyBytes);

    // Ensure the image is loaded correctly
    if (image == null) {
      return (null, 'Error: Unable to decode image.');
    }

    return (image, null);
  }
  else {
    return (null, 'Failed to load image. Status code: ${response.statusCode}');
  }
}

class WikiResult {
  final String title;
  final String extract;
  final String? thumbUri;
  final int? thumbWidth;
  final int? thumbHeight;

  const WikiResult({
    required this.title,
    required this.extract,
    this.thumbUri,
    this.thumbWidth,
    this.thumbHeight
  });

  factory WikiResult.fromJson(Map<String, dynamic> json) {
    String? thumbUri;
    int? thumbWidth, thumbHeight;

    if (json['query'] == null) {
      throw const FormatException('No pages found');
    }

    Map<String, dynamic> page = json['query']['pages'][json['query']['pages'].keys.first] as Map<String, dynamic>;
    String title = page['title'] as String;
    String extract = page['extract'] as String;

    if (page.containsKey('thumbnail')) {
      Map<String, dynamic> thumb = page['thumbnail'] as Map<String, dynamic>;
      thumbUri = thumb['source'] as String;
      thumbWidth = thumb['width'] as int;
      thumbHeight = thumb['height'] as int;
    }

    return WikiResult(
          title: title,
          extract: extract,
          thumbUri: thumbUri,
          thumbWidth: thumbWidth,
          thumbHeight: thumbHeight
        );
  }
}
