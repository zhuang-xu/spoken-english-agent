import json

from app.schemas import Evaluation, Session, TranscriptItem
from app.services.llm import LLMClient


EVALUATOR_SYSTEM_PROMPT = """You evaluate English speaking practice sessions.
Return strict JSON with these keys:
fluency_feedback, grammar_feedback, vocabulary_feedback, pronunciation_pace_feedback, top_3_issues, next_practice_suggestion.
Be specific, encouraging, and actionable. If pronunciation or pace metrics are absent, say feedback is limited."""


class Evaluator:
    def __init__(self, llm: LLMClient):
        self.llm = llm

    def evaluate(self, session: Session, transcript: list[TranscriptItem]) -> Evaluation:
        result = self.llm.complete_json(
            EVALUATOR_SYSTEM_PROMPT,
            "Create final evaluation for this session:\n"
            + json.dumps(
                {
                    "session": session.model_dump(mode="json"),
                    "transcript": [item.model_dump(mode="json") for item in transcript],
                }
            ),
        )
        return Evaluation.model_validate(result)
