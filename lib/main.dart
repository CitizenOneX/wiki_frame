import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:simple_frame_app/text_utils.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
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
  String _extract = '';
  img.Image? _image;

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
  /// So the lifetime of this run() is only 5 seconds or so.
  /// It has a running main loop on the Frame (frame_app.lua)
  @override
  Future<void> run() async {
    currentState = ApplicationState.running;
    if (mounted) setState(() {});

    // listen for STT
    await _speechToText.listen(
      listenOptions: SpeechListenOptions(
        cancelOnError: true, onDevice: true, listenMode: ListenMode.search
      ),
      onResult: (SpeechRecognitionResult result) async {
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
              _finalResult = result.title;
              if (mounted) setState((){});
              // send result.extract to Frame ( TODO regex strip non-printable? )
              await frame!.sendMessage(TxPlainText(msgCode: 0x0a, text: _extract));
              _prevText = _extract;

              if (result.thumbUri != null) {
                // first, download the image into an image/image
                img.Image? thumbnail;
                (thumbnail, error) = await fetchThumbnail(result.thumbUri!);

                if (thumbnail != null) {
                  // Compute an optimal 15/16-color palette from the image? Monochrome?
                  // TODO try different dithering methods, quantization methods?
                  _image = thumbnail;
                  try {
                    // Quantization to 16-color doesn't perform consistently well, use 2-bit for now
                    // for binary quantization, setting numberOfColors=2 results in a 1 color(!) image in some cases
                    // so ask for 4 and get back 2 anyway
                    _image = img.quantize(thumbnail, numberOfColors: 4, method: img.QuantizeMethod.binary, dither: img.DitherKernel.floydSteinberg, ditherSerpentine: false);
                    _log.fine('Colors in palette: ${_image!.palette!.numColors} ${_image!.palette!.toUint8List()}');

                    // just in case the image height is longer than 400, crop it here (width should be set at 240 by wikipedia)
                    if (_image!.height > 400) {
                      _image = img.copyCrop(_image!, x: 0, y: 0, width: 240, height: 400);
                    }

                    // send image message (header and image data) to Frame
                    await frame!.sendMessage(TxSprite(
                      msgCode: 0x0d,
                      width: _image!.width,
                      height: _image!.height,
                      numColors: _image!.palette!.numColors,
                      paletteData: _image!.palette!.toUint8List(),
                      pixelData: _image!.data!.toUint8List()));
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
            _extract = error!;
            _image = null;
          }

          // final result is done
          currentState = ApplicationState.ready;
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
      },
    );
  }

  /// The run() function will run for 5 seconds or so, but if the user
  /// interrupts it, we can cancel the speech to text/wiki search and return to ApplicationState.ready state.
  @override
  Future<void> cancel() async {
    await _stopListening();
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
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
                          child: Text(_extract,
                            style: const TextStyle(color: Colors.white, fontSize: 18),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Container(
                          alignment: Alignment.topCenter,
                          color: Colors.black,
                          child: (_image != null) ? Image.memory(
                            img.encodePng(_image!),
                            gaplessPlayback: true,
                            fit: BoxFit.cover,
                          ) : null
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
