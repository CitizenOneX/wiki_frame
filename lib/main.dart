import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

Future<WikiResult> fetchWiki() async {

  final response = await http
      .get(Uri.parse('https://en.wikipedia.org/w/api.php?action=query&format=json&prop=pageimages%7Cpageterms%7cinfo&inprop=url&generator=prefixsearch&redirects=1&formatversion=2&piprop=thumbnail&pithumbsize=200&pilimit=10&wbptterms=description&gpssearch=weezer&gpsoffset=10'));

  if (response.statusCode == 200) {
    // If the server did return a 200 OK response,
    // then parse the JSON.
    return WikiResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
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

    Map<String, dynamic> page = json['query']['pages'][0];
    int pageid = page['pageid'];
    String title = page['title'];
    String description = page['terms']['description'][0];

    if (page.containsKey('thumbnail')) {
      Map<String, dynamic> thumb = page['thumbnail'];
      thumbUri = thumb['source'];
      thumbWidth = thumb['width'];
      thumbHeight = thumb['height'];
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

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late Future<WikiResult> futureWikiResult;

  @override
  void initState() {
    super.initState();
    futureWikiResult = fetchWiki();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wikipedia Search',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Wikipedia Search'),
        ),
        body: Center(
          child: FutureBuilder<WikiResult>(
            future: futureWikiResult,
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                return Text(snapshot.data!.title);
              } else if (snapshot.hasError) {
                return Text('${snapshot.error}');
              }

              // By default, show a loading spinner.
              return const CircularProgressIndicator();
            },
          ),
        ),
      ),
    );
  }
}