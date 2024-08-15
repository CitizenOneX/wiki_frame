# wiki_frame

Listens for a search phrase from the user, queries Wikipedia and returns an extract for display in Frame

Tested on Android, but should be able to work on iOS also.

Flutter package `speech_to_text` uses platform-provided speech to text capability, apparently either on-device or cloud-based (although here we request `onDevice`). It uses the system microphone, which will be either the phone or possibly a connected bluetooth headset, but unless/until Frame could be connected as a bluetooth mic, it can't be used as we can't feed its streamed audio into the platform speech service.
Alternatives that can be fed streamed audio bytes include Vosk, but that is Android-only.
