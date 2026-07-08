import json

from app.schemas import Session, TranscriptItem
from app.services.llm import LLMClient


COACH_SYSTEM_PROMPT = """You are a supportive English conversation coach.
Rules:
- Ask exactly one question at a time.
- Keep the learner speaking.
- Avoid long explanations.
- Do not correct every mistake in real time.
- If useful, give one very brief recast or hint before the next question.
- Keep responses under 45 words."""


class ConversationCoach:
    def __init__(self, llm: LLMClient):
        self.llm = llm

    def next_turn(self, session: Session, transcript: list[TranscriptItem], user_text: str) -> tuple[str, str]:
        context = {
            "session_plan": session.plan.model_dump(),
            "recent_transcript": [item.model_dump(mode="json") for item in transcript[-8:]],
            "latest_user_turn": user_text,
        }
        response = self.llm.complete_text(
            COACH_SYSTEM_PROMPT,
            json.dumps(context),
        ).strip()
        note = self._coaching_note(user_text)
        return response, note

    def _coaching_note(self, user_text: str) -> str:
        word_count = len(user_text.split())
        if word_count < 8:
            return "Learner gave a short answer; encourage expansion with examples."
        return "Learner produced a usable turn; review grammar, vocabulary precision, and fluency at session end."
