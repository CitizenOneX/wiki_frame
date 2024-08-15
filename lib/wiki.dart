import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final _log = Logger("Wiki");

/// Simple function for retrieving basic content from Wikipedia based on a couple of search terms
Future<WikiResult> fetchWiki(String query) async {
  final response = await http
      .get(Uri.parse('https://en.wikipedia.org/w/api.php?action=query&format=json&prop=pageimages%7Cpageterms%7cinfo&inprop=url&generator=prefixsearch&redirects=1&formatversion=2&piprop=thumbnail&pithumbsize=200&pilimit=10&wbptterms=description&gpssearch=${const HtmlEscape().convert(query)}&gpsoffset=0'));

  if (response.statusCode == 200) {
    // If the server did return a 200 OK response,
    // then parse the JSON.
    try {
      return WikiResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    } catch (e) {
      _log.fine('error parsing JSON: $e');
      return const WikiResult(pageId: -1, title: 'Error', description: 'No matching page found');
    }
  } else {
    // If the server did not return a 200 OK response,
    // then throw an exception.
    throw Exception('Failed to load wiki result');
  }
}

class WikiResult {
  final int pageId;
  final String title;
  final String description;
  final String? thumbUri;
  final int? thumbWidth;
  final int? thumbHeight;

  const WikiResult({
    required this.pageId,
    required this.title,
    required this.description,
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

    Map<String, dynamic> page = json['query']['pages'][0] as Map<String, dynamic>;
    int pageid = page['pageid'] as int;
    String title = page['title'] as String;
    String description = page['terms']['description'][0] as String;

    if (page.containsKey('thumbnail')) {
      Map<String, dynamic> thumb = page['thumbnail'] as Map<String, dynamic>;
      thumbUri = thumb['source'] as String;
      thumbWidth = thumb['width'] as int;
      thumbHeight = thumb['height'] as int;
    }

    return WikiResult(
          pageId: pageid,
          title: title,
          description: description,
          thumbUri: thumbUri,
          thumbWidth: thumbWidth,
          thumbHeight: thumbHeight
        );
  }
}
