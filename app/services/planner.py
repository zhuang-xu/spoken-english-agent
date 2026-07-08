import json

from app.schemas import SessionCreate, SessionPlan
from app.services.llm import LLMClient


PLANNER_SYSTEM_PROMPT = """You are a session planner for an English speaking practice app.
Return strict JSON with these keys:
topic, opening_question, follow_up_strategy, target_expressions, evaluation_rubric.
Create a realistic plan for one turn-based speaking session. Keep the opening question short."""


class SessionPlanner:
    def __init__(self, llm: LLMClient):
        self.llm = llm

    def create_plan(self, request: SessionCreate) -> SessionPlan:
        payload = request.model_dump()
        result = self.llm.complete_json(
            PLANNER_SYSTEM_PROMPT,
            f"Create a session plan for this learner:\n{json.dumps(payload)}",
        )
        return SessionPlan.model_validate(result)
