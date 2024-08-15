import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:http/http.dart' as http;

import 'frame_helper.dart';
import 'simple_frame_app.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

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

    debugPrint(json.toString());

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

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

/// SimpleFrameAppState mixin helps to manage the lifecycle of the Frame connection outside of this file
class MainAppState extends State<MainApp> with SimpleFrameAppState {

  MainAppState() {
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  /// Wiki Frame application members
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;

  String _partialResult = "N/A";
  String _finalResult = "N/A";
  static const _textStyle = TextStyle(fontSize: 30);

  // Wikipedia query results
  Future<WikiResult>? _futureWikiResult;


  @override
  void initState() {
    super.initState();
    currentState = ApplicationState.initializing;
    // asynchronously kick off Speech-to-text initialization
    _initSpeech();
  }

  @override
  void dispose() async {
    _speechToText.cancel();
    super.dispose();
  }

  /// This has to happen only once per app
  void _initSpeech() async {
    _speechEnabled = await _speechToText.initialize();
    if (!_speechEnabled) {
        _log.severe('The user has denied the use of speech recognition');
      currentState = ApplicationState.disconnected;
    }
    else {
      _log.fine('Speech-to-text initialized');
      currentState = ApplicationState.ready;
    }

    if (mounted) setState(() {});
  }

  /// Each time to start a speech recognition session
  Future<void> _startListening() async {
    await _speechToText.listen(onResult: _onSpeechResult, listenOptions: SpeechListenOptions(cancelOnError: true, onDevice: true, listenMode: ListenMode.search));
    if (mounted) setState(() {});
  }

  /// Manually stop the active speech recognition session
  /// Note that there are also timeouts that each platform enforces
  /// and the SpeechToText plugin supports setting timeouts on the
  /// listen method.
  Future<void> _stopListening() async {
    await _speechToText.stop();
    if (mounted) setState(() {});
  }

  /// This is the callback that the SpeechToText plugin calls when
  /// the platform returns recognized words.
  void _onSpeechResult(SpeechRecognitionResult result) {
    setState(() {
      if (result.finalResult) {
        _finalResult = result.recognizedWords;
        _partialResult = '';
        _log.fine('Final result: $_finalResult');
        _futureWikiResult = fetchWiki(_finalResult);
        _stopListening();

        currentState = ApplicationState.ready;
        if (mounted) setState(() {});
      }
      else {
        // partial result
        _partialResult = result.recognizedWords;
        _log.fine('Partial result: $_partialResult, ${result.alternates}');
      }
    });
  }

  /// This application uses platform speech-to-text to listen to audio from the host mic, convert to text,
  /// and send the text to the Frame. It has a running main loop on the Frame (frame_app.lua)
  @override
  Future<void> runApplication() async {
    currentState = ApplicationState.running;
    _partialResult = '';
    _finalResult = '';
    if (mounted) setState(() {});

    try {
      // listen for STT
      await _startListening();
/*
      // try to get the Frame into a known state by making sure there's no main loop running
      frame!.sendBreakSignal();
      await Future.delayed(const Duration(milliseconds: 500));

      // clean up by deregistering any handler and deleting any prior script
      await frame!.sendString('frame.bluetooth.receive_callback(nil);print(0)', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));
      await frame!.sendString('frame.file.remove("frame_app.lua");print(0)', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));

      // send our frame_app to the Frame
      // it listens to data being sent and renders the text on the display
      await frame!.uploadScript('frame_app.lua', 'assets/frame_app.lua');
      await Future.delayed(const Duration(milliseconds: 500));

      // kick off the main application loop
      await frame!.sendString('require("frame_app")', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));
*/
      // -----------------------------------------------------------------------
      // frame_app is installed on Frame and running, start our application loop
      // -----------------------------------------------------------------------

      String prevText = '';

/*
        // if the user has clicked Stop we want to jump out of the main loop and stop processing
        if (currentState != ApplicationState.running) {
          break;
        }

        // recognizer blocks until it has something
        final resultReady = await _recognizer.acceptWaveformBytes(Uint8List.fromList(audioSample));

        // TODO consider enabling alternatives, and word times, and ...?
        String text = resultReady ?
            jsonDecode(await _recognizer.getResult())['text'] as String
          : jsonDecode(await _recognizer.getPartialResult())['partial'] as String;

        // If the text is the same as the previous one, we don't send it to Frame and force a redraw
        // The recognizer often produces a bunch of empty string in a row too, so this means
        // we send the first one (clears the display) but not subsequent ones
        // Often the final result matches the last partial, so if it's a final result then show it
        // on the phone but don't send it
        if (text == prevText) {
          if (resultReady) {
            setState(() { _finalResult = text; _partialResult = ''; });
          }
          continue;
        }
        else if (text.isEmpty) {
          // turn the empty string into a single space and send
          // still can't put it through the wrapped-text-chunked-sender
          // because it will be zero bytes payload so no message will
          // be sent.
          // Users might say this first empty partial
          // comes a bit soon and hence the display is cleared a little sooner
          // than they want (not like audio hangs around in the air though
          // after words are spoken!)
          //TODO frame!.sendData([0x0b, 0x20]);
          prevText = '';
          continue;
        }

        if (_log.isLoggable(Level.FINE)) {
          _log.fine('Recognized text: $text');
        }

        // sentence fragments can be longer than MTU (200-ish bytes) so we introduce a header
        // byte to indicate if this is a non-final chunk or a final chunk, which is interpreted
        // on the other end in frame_app
        try {
          // send current text to Frame, splitting into "longText"-marked chunks if required
          String wrappedText = FrameHelper.wrapText(text, 640, 4);

          int sentBytes = 0;
          int bytesRemaining = wrappedText.length;
          //TODO int chunksize = frame!.maxDataLength! - 1;
          int chunksize = 200;
          List<int> bytes;

          while (sentBytes < wrappedText.length) {
            if (bytesRemaining <= chunksize) {
              // final chunk
              bytes = [0x0b] + wrappedText.substring(sentBytes, sentBytes + bytesRemaining).codeUnits;
            }
            else {
              // non-final chunk
              bytes = [0x0a] + wrappedText.substring(sentBytes, sentBytes + chunksize).codeUnits;
            }

            // send the chunk
            //TODO frame!.sendData(bytes);

            sentBytes += bytes.length;
            bytesRemaining = wrappedText.length - sentBytes;
          }
        }
        catch (e) {
          _log.severe('Error sending text to Frame: $e');
          break;
        }

        // update the phone UI too
        setState(() => resultReady ? _finalResult = text : _partialResult = text);
        prevText = text;
        // recognized our query word, break out of audio and fetch the content
        if (resultReady) {
          break;
        }

      _futureWikiResult = fetchWiki(_finalResult);

      // ----------------------------------------------------------------------
      // finished the main application loop, shut it down here and on the Frame
      // ----------------------------------------------------------------------

      await _stopListening();
  */
/*
      // send a break to stop the Lua app loop on Frame
      await frame!.sendBreakSignal();
      await Future.delayed(const Duration(milliseconds: 500));

      // deregister the data handler
      await frame!.sendString('frame.bluetooth.receive_callback(nil);print(0)', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));
*/
    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }

    //currentState = ApplicationState.ready;
    //if (mounted) setState(() {});
    // stays running when it exits, either speech recognized or timeout sends us back to ApplicationState.ready
  }

  /// The runApplication function will keep running until we interrupt it here
  /// and tell it to start shutting down. It will interrupt the frame_app
  /// and perform the cleanup on Frame and here
  @override
  Future<void> interruptApplication() async {
    currentState = ApplicationState.stopping;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // work out the states of the footer buttons based on the app state
    List<Widget> pfb = [];

    switch (currentState) {
      case ApplicationState.disconnected:
        pfb.add(TextButton(onPressed: scanOrReconnectFrame, child: const Text('Connect Frame')));
        pfb.add(TextButton(onPressed: runApplication, child: const Text('Start')));
        pfb.add(TextButton(onPressed: interruptApplication, child: const Text('Stop')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;

      case ApplicationState.initializing:
      case ApplicationState.scanning:
      case ApplicationState.connecting:
      case ApplicationState.disconnecting:
      case ApplicationState.stopping:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;

      case ApplicationState.ready:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(TextButton(onPressed: runApplication, child: const Text('Start')));
        pfb.add(TextButton(onPressed: disconnectFrame, child: const Text('Finish')));
        break;

      case ApplicationState.running:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(TextButton(onPressed: interruptApplication, child: const Text('Stop')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;
    }

    return MaterialApp(
      title: 'Wiki Frame',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Wiki Frame"),
          actions: [getBatteryWidget()]
        ),
        body: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Align(alignment: Alignment.centerLeft,
                  child: Text('Query: ${_partialResult == '' ? _finalResult : _partialResult}', style: _textStyle)
                ),
                const Divider(),
                Align(alignment: Alignment.centerLeft,
                  child: FutureBuilder<WikiResult>(
                    future: _futureWikiResult,
                    builder: (context, snapshot) {
                      if (snapshot.hasData) {
                        return Text('${snapshot.data!.title}:\n${snapshot.data!.description}', style: _textStyle);
                      } else if (snapshot.hasError) {
                        return Text('${snapshot.error}', style: _textStyle);
                      }

                      // By default, show a loading spinner.
                      return const Text('Make a query!', style: _textStyle);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        persistentFooterButtons: pfb,
      ),
    );
  }
}
