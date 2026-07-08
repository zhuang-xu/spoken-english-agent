import base64
import tempfile
from pathlib import Path

import azure.cognitiveservices.speech as speechsdk

from app.config import Settings


class SpeechService:
    def transcribe(self, audio_bytes: bytes, suffix: str = ".wav") -> str:
        raise NotImplementedError

    def synthesize_base64(self, text: str) -> str | None:
        raise NotImplementedError


class MockSpeechService(SpeechService):
    def transcribe(self, audio_bytes: bytes, suffix: str = ".wav") -> str:
        return "[mock transcript from uploaded audio]"

    def synthesize_base64(self, text: str) -> str | None:
        return None


class AzureSpeechService(SpeechService):
    def __init__(self, settings: Settings):
        if not settings.azure_speech_key or not settings.azure_speech_region:
            raise ValueError("Azure Speech key and region are required when PROVIDER=azure.")
        self.settings = settings
        self.speech_config = speechsdk.SpeechConfig(
            subscription=settings.azure_speech_key,
            region=settings.azure_speech_region,
        )
        self.speech_config.speech_recognition_language = settings.azure_speech_recognition_language
        self.speech_config.speech_synthesis_voice_name = settings.azure_speech_voice

    def transcribe(self, audio_bytes: bytes, suffix: str = ".wav") -> str:
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as audio_file:
            audio_file.write(audio_bytes)
            audio_path = Path(audio_file.name)
        try:
            audio_config = speechsdk.AudioConfig(filename=str(audio_path))
            recognizer = speechsdk.SpeechRecognizer(
                speech_config=self.speech_config,
                audio_config=audio_config,
            )
            result = recognizer.recognize_once_async().get()
            if result.reason == speechsdk.ResultReason.RecognizedSpeech:
                return result.text
            if result.reason == speechsdk.ResultReason.NoMatch:
                raise ValueError("Speech could not be recognized from the uploaded audio.")
            cancellation = speechsdk.CancellationDetails(result)
            raise ValueError(f"Speech recognition canceled: {cancellation.reason}")
        finally:
            audio_path.unlink(missing_ok=True)

    def synthesize_base64(self, text: str) -> str | None:
        synthesizer = speechsdk.SpeechSynthesizer(
            speech_config=self.speech_config,
            audio_config=None,
        )
        result = synthesizer.speak_text_async(text).get()
        if result.reason != speechsdk.ResultReason.SynthesizingAudioCompleted:
            cancellation = speechsdk.CancellationDetails(result)
            raise ValueError(f"Speech synthesis canceled: {cancellation.reason}")
        return base64.b64encode(result.audio_data).decode("ascii")


def build_speech_service(settings: Settings) -> SpeechService:
    if settings.provider == "azure":
        return AzureSpeechService(settings)
    return MockSpeechService()
