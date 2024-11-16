import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:simple_frame_app/rx/tap.dart';
import 'package:simple_frame_app/text_utils.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/tx/code.dart';
import 'package:simple_frame_app/tx/image_sprite_block.dart';
import 'package:simple_frame_app/tx/sprite.dart';
import 'package:simple_frame_app/tx/plain_text.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'wiki.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

/// SimpleFrameAppState mixin helps to manage the lifecycle of the Frame connection outside of this file
class MainAppState extends State<MainApp> with SimpleFrameAppState {

  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  // Speech to text members
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  String _partialResult = "N/A";
  String _finalResult = "N/A";
  String? _prevText;

  // Wiki members
  List<String>? _extract;
  int _currentPage = -1; // 5 lines of the wiki extract per page
  Image? _image;

  // tap subscription
  StreamSubscription<int>? _tapSubs;

  static const _textStyle = TextStyle(fontSize: 30);

  @override
  void initState() {
    super.initState();

    // asynchronously kick off Speech-to-text initialization
    currentState = ApplicationState.initializing;
    _initSpeech();
  }

  @override
  void dispose() async {
    _speechToText.cancel();
    super.dispose();
  }

  /// This has to happen only once per app, but microphone permission must be provided
  void _initSpeech() async {
    _speechEnabled = await _speechToText.initialize(onError: _onSpeechError);

    if (!_speechEnabled) {
      _finalResult = 'The user has denied the use of speech recognition. Microphone permission must be added manually in device settings.';
      _log.severe(_finalResult);
      currentState = ApplicationState.disconnected;
    }
    else {
      _log.fine('Speech-to-text initialized');
      // this will initialise before Frame is connected, so proceed to disconnected state
      currentState = ApplicationState.disconnected;
    }

    if (mounted) setState(() {});
  }

  /// Manually stop the active speech recognition session, but timeouts will also stop the listening
  Future<void> _stopListening() async {
    await _speechToText.stop();
  }

  /// Timeouts invoke this function, but also other permanent errors
  void _onSpeechError(SpeechRecognitionError error) {
    if (error.errorMsg != 'error_speech_timeout') {
      _log.severe(error.errorMsg);
      currentState = ApplicationState.ready;
    }
    else {
      currentState = ApplicationState.running;
    }
    if (mounted) setState(() {});
  }

  /// This application uses platform speech-to-text to listen to audio from the host mic, convert to text,
  /// and send the text to the Frame.
  /// A Wiki query is also sent, and the resulting content is shown in Frame.
  /// The lifetime of this run() is short, it sets up the listeners for taps and speech but keeps application state as running.
  /// It has a running main loop on the Frame (frame_app.lua)
  @override
  Future<void> run() async {
    currentState = ApplicationState.running;
    if (mounted) setState(() {});

    // listen for taps for next(1)/prev(2) page and new query (3)
    _tapSubs?.cancel();
    _tapSubs = RxTap().attach(frame!.dataResponse)
      .listen((taps) async {
        _log.fine(() => 'taps: $taps, currentPageBeforeTap: $_currentPage, extractLength: ${_extract?.length}');
        switch (taps) {
          case 1:
            // next
            if (_extract != null) {
              if (nextPage()) {
                await frame!.sendMessage(TxPlainText(msgCode: 0x0a, text: getCurrentPageText()));
                setState((){});
              }
            }
            break;
          case 2:
            // prev
            if (_extract != null) {
              if (previousPage()) {
                await frame!.sendMessage(TxPlainText(msgCode: 0x0a, text: getCurrentPageText()));
                setState((){});
              }
            }
            break;
          case 3:
            // new query
            _currentPage = -1;
            setState((){});
            await _speechToText.listen(
              listenOptions: SpeechListenOptions(
                cancelOnError: true, onDevice: true, listenMode: ListenMode.search
              ),
              onResult: processSpeechRecognitionResult,
            );
            break;
          default:
        }
      }
    );

    // let Frame know to subscribe for taps and send them to us
    await frame!.sendMessage(TxCode(msgCode: 0x10, value: 1));

    // prompt the user to begin tapping
    await frame!.sendMessage(TxPlainText(msgCode: 0x0a, text: '3-Tap for new query\n____\n1-Tap next page\n2-Tap previous page'));
  }

  /// The run() function will run for 5 seconds or so, but if the user
  /// interrupts it, we can cancel the speech to text/wiki search and return to ApplicationState.ready state.
  @override
  Future<void> cancel() async {
    // cancel listening (only if we currently are)
    await _stopListening();

    // let Frame know to stop sending taps
    await frame!.sendMessage(TxCode(msgCode: 0x10, value: 0));

    // clear the display
    await frame!.sendMessage(TxPlainText(msgCode: 0x0a, text: ' '));

    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  void processSpeechRecognitionResult(SpeechRecognitionResult result) async {
    if (currentState == ApplicationState.ready) {
      // user has cancelled already, don't process result
      return;
    }

    if (result.finalResult) {
      // on a final result we fetch the wiki content
      _finalResult = result.recognizedWords;
      _partialResult = '';
      _log.fine('Final result: $_finalResult');
      _stopListening();
      // send final query text to Frame line 1 (before we confirm the title)
      if (_finalResult != _prevText) {
        await frame!.sendMessage(TxPlainText(msgCode: 0x0a, text: _finalResult));
        _prevText = _finalResult;
      }

      // kick off the http request sequence
      String? error;
      String? title;
      (title, error) = await findBestPage(_finalResult);

      if (title != null) {
        // send page title to Frame on row 1
        if (title != _prevText) {
          await frame!.sendMessage(TxPlainText(msgCode: 0x0a, text: title));
          _prevText = title;
        }

        WikiResult? result;
        String? error;
        (result, error) = await fetchExtract(title);

        if (result != null) {
          _extract = TextUtils.wrapText('${result.title}\n${result.extract}', 400, 4);
          _currentPage = 0;
          _finalResult = result.title;
          if (mounted) setState((){});
          // send first 5 rows of result.extract to Frame ( TODO regex strip non-printable? )
          await frame!.sendMessage(TxPlainText(msgCode: 0x0a, text: getCurrentPageText()));
          _prevText = '';

          if (result.thumbUri != null) {
            // first, download the image into an image/image
            Uint8List? imageBytes;
            (imageBytes, error) = await fetchThumbnail(result.thumbUri!);

            if (imageBytes != null) {
              try {
                // Update the UI based on the original image
                setState(() {
                  _image = Image.memory(imageBytes!, gaplessPlayback: true, fit: BoxFit.cover);
                });

                // yield here a moment in order to show the first image first
                await Future.delayed(const Duration(milliseconds: 10));

                var sprite = TxSprite.fromImageBytes(msgCode: 0x0d, imageBytes: imageBytes);

                // Update the UI with the modified image
                setState(() {
                  _image = Image.memory(img.encodePng(sprite.toImage()), gaplessPlayback: true, fit: BoxFit.cover);
                });

                // create the image sprite block header and its sprite lines
                // based on the sprite
                TxImageSpriteBlock isb = TxImageSpriteBlock(
                  msgCode: 0x0d,
                  image: sprite,
                  spriteLineHeight: 20,
                  progressiveRender: true);

                // and send the block header then the sprite lines to Frame
                await frame!.sendMessage(isb);

                for (var sprite in isb.spriteLines) {
                  await frame!.sendMessage(sprite);
                }
              }
              catch (e) {
                _log.severe('Error processing image: $e');
              }
            }
            else {
              _log.fine('Error fetching thumbnail for "$_finalResult": "${result.thumbUri!}" - "$error"');
            }
          }
          else {
            // no thumbnail for this entry
            _image = null;
          }
        }
      }
      else {
        _log.fine('Error searching for "$_finalResult" - "$error"');
        _extract = [];
        await frame!.sendMessage(TxPlainText(msgCode: 0x0a, text: TextUtils.wrapText(error!, 400, 4).join('\n')));
        _image = null;
        setState((){});
      }

      // final result is done
      if (mounted) setState(() {});
    }
    else {
      // partial result - just display in-progress text
      _partialResult = result.recognizedWords;
      if (mounted) setState((){});

      _log.fine('Partial result: $_partialResult, ${result.alternates}');
      if (_partialResult != _prevText) {
        // send partial result to Frame line 1
        await frame!.sendMessage(TxPlainText(msgCode: 0x0a, text: _partialResult));
        _prevText = _partialResult;
      }
    }
  }

  String getCurrentPageText() {
    if (_extract != null && _currentPage >= 0) {
      return _extract!.sublist(_currentPage * 5, min((_currentPage + 1) * 5, _extract!.length)).join('\n');
    }
    else {
      return '';
    }
  }

  bool nextPage() {
    if (_extract != null && _extract!.length > ((_currentPage + 1) * 5) && _currentPage >= 0) {
      _currentPage++;
      return true;
    }
    else {
      return false;
    }
  }

  bool previousPage() {
    if (_extract != null && _currentPage > 0) {
      _currentPage--;
      return true;
    }
    else {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
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
                SizedBox(
                  width: 640,
                  height: 400,
                  child: Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: Container(
                          alignment: Alignment.topCenter,
                          color: Colors.black,
                          child: Text(getCurrentPageText(),
                            style: const TextStyle(color: Colors.white, fontSize: 18),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Container(
                          alignment: Alignment.topCenter,
                          color: Colors.black,
                          child: (_image != null) ? _image! : null
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.search), const Icon(Icons.cancel)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}
