import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'frame_helper.dart';
import 'simple_frame_app.dart';
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
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  // Speech to text members
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  String _partialResult = "N/A";
  String _finalResult = "N/A";
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

  /// Each time we are listening for a wiki search query
  Future<void> _startListening() async {
    await _speechToText.listen(
      onResult: _onSpeechResult,
      listenOptions: SpeechListenOptions(
        cancelOnError: true, onDevice: true, listenMode: ListenMode.search));
  }

  /// Manually stop the active speech recognition session, but timeouts will also stop the listening
  Future<void> _stopListening() async {
    await _speechToText.stop();
  }

  /// This is the callback that the SpeechToText plugin calls when
  /// the platform returns recognized words.
  void _onSpeechResult(SpeechRecognitionResult result) async {
    if (currentState == ApplicationState.ready) {
      // user has cancelled already, don't process result
      // FIXME reinstate
      //return;
    }

    if (result.finalResult) {
      // on a final result we fetch the wiki content
      _finalResult = result.recognizedWords;
      _partialResult = '';
      _log.fine('Final result: $_finalResult');
      _stopListening();
      // TODO send final query text to Frame line 1, don't await (before we confirm the title)

      // kick off the http request sequence
      String? error;
      String? title;
      (title, error) = await findBestPage(_finalResult);

      // TODO send page title to Frame on row 1 (don't await)

      if (title != null) {
        WikiResult? result;
        String? error;
        (result, error) = await fetchExtract(title);

        if (result != null) {
          _extract = FrameHelper.wrapText(result.extract, 400, 4);
          _finalResult = result.title;
          if (mounted) setState((){});
          // TODO FrameHelper.sendLongString etc result.extract (regex strip non-printable?) to Frame (wrap width = 400?)

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

                // send image message to Frame (split over several packets)
                var fullPayload = makeImagePayload(_image!);

                // FIXME remove frame check
                if (frame != null) {
                  int sentBytes = 0;
                  int bytesRemaining = fullPayload.length;
                  int chunksize = frame!.maxDataLength! - 1;
                  List<int> packet = List.filled(frame!.maxDataLength!, 0x0d);

                  while (sentBytes < fullPayload.length) {
                    if (bytesRemaining <= chunksize) {
                      // final image chunk
                      packet = List.filled(bytesRemaining + 1, 0x0d);
                      packet.setAll(1, fullPayload.getRange(sentBytes, sentBytes + bytesRemaining));
                    }
                    else {
                      // non-final chunk
                      packet.setAll(1, fullPayload.getRange(sentBytes, sentBytes + chunksize));
                    }

                    // send the chunk
                    frame!.sendData(packet);

                    sentBytes += packet.length;
                    bytesRemaining = fullPayload.length - sentBytes;
                  }
                }
              }
              catch (e) {
                _log.severe('Error processing image: $e');
              }
              if (mounted) setState((){});
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

      currentState = ApplicationState.ready;
      if (mounted) setState(() {});
    }
    else {
      // partial result - just display in-progress text
      _partialResult = result.recognizedWords;
      if (mounted) setState((){});

      _log.fine('Partial result: $_partialResult, ${result.alternates}');
      // TODO also send partial query text to Frame line 1 (if different to previous _partialResult - seem to get duplicates)
    }
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

  /// Corresponding parser in frame_app.lua data_handler()
  /// width(Uint16), height(Uint16), bpp(Uint8), numColors(Uint8), palette (Uint8 r, Uint8 g, Uint8 b)*numColors, data (length width x height x bpp/8)
  List<int> makeImagePayload(img.Image image) {
    int widthMsb = image.width >> 8;
    int widthLsb = image.width & 0xFF;
    int heightMsb = image.height >> 8;
    int heightLsb = image.height & 0xFF;
    int numColors = image.palette!.numColors;
    int bpp = 0;
    Uint8List packed;
    switch (image.palette!.numColors) {
      case <= 2:
        bpp = 1;
        packed = pack1Bit(image.data!.buffer.asUint8List());
        break;
      case <= 4:
        bpp = 2;
        packed = pack2Bit(image.data!.buffer.asUint8List());
        break;
      case <= 16:
        bpp = 4;
        packed = pack4Bit(image.data!.buffer.asUint8List());
        break;
      default:
        throw Exception('Image must have 16 or fewer colors. Actual: ${image.palette!.numColors}');
    }

    // preallocate the list of bytes to send - header, palette, data
    List<int> payload = List.filled((6 + numColors * 3 + image.width * image.height * bpp/8).toInt(), 0);

    payload.setAll(0, [widthMsb, widthLsb, heightMsb, heightLsb, bpp, numColors]);
    payload.setAll(6, image.palette!.toUint8List());
    payload.setAll(6 + numColors * 3, packed);

    return payload;
  }

  Uint8List pack1Bit(Uint8List bpp1) {
    int byteLength = (bpp1.length + 7) ~/ 8;  // Calculate the required number of bytes
    Uint8List packed = Uint8List(byteLength); // Create the Uint8List to hold packed bytes

    for (int i = 0; i < bpp1.length; i++) {
      int byteIndex = i ~/ 8;
      int bitIndex = i % 8;
      packed[byteIndex] |= (bpp1[i] & 0x01) << (7 - bitIndex);
    }

    return packed;
  }

  Uint8List pack2Bit(Uint8List bpp2) {
    int byteLength = (bpp2.length + 3) ~/ 4;  // Calculate the required number of bytes
    Uint8List packed = Uint8List(byteLength); // Create the Uint8List to hold packed bytes

    for (int i = 0; i < bpp2.length; i++) {
      int byteIndex = i ~/ 4;
      int bitOffset = (3 - (i % 4)) * 2;
      packed[byteIndex] |= (bpp2[i] & 0x03) << bitOffset;
    }

    return packed;
  }

  Uint8List pack4Bit(Uint8List bpp4) {
    int byteLength = (bpp4.length + 1) ~/ 2;  // Calculate the required number of bytes
    Uint8List packed = Uint8List(byteLength); // Create the Uint8List to hold packed bytes

    for (int i = 0; i < bpp4.length; i++) {
      int byteIndex = i ~/ 2;
      int bitOffset = (1 - (i % 2)) * 4;
      packed[byteIndex] |= (bpp4[i] & 0x0F) << bitOffset;
    }

    return packed;
  }

  /// This application uses platform speech-to-text to listen to audio from the host mic, convert to text,
  /// and send the text to the Frame.
  /// A Wiki query is also sent, and the resulting content is shown in Frame.
  /// So the lifetime of this run() is only 5 seconds or so.
  /// It has a running main loop on the Frame (frame_app.lua)
  @override
  Future<void> run() async {
    currentState = ApplicationState.running;
    _partialResult = '';
    _finalResult = '';
    if (mounted) setState(() {});

    try {
      // listen for STT
      await _startListening();

      //TODO move to speech to text onResult? Or move it in here?
/*
      String prevText = '';
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
          if (frame!=null) frame!.sendData(bytes);

          sentBytes += bytes.length;
          bytesRemaining = wrappedText.length - sentBytes;
        }
      }
      catch (e) {
        _log.severe('Error sending text to Frame: $e');
        break;
      }

      prevText = text;
  */
    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }
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
    // FIXME remove
    currentState = ApplicationState.ready;
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
