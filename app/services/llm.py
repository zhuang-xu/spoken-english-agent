import json
from typing import Any

from openai import AzureOpenAI

from app.config import Settings


class LLMClient:
    def complete_json(self, system: str, user: str) -> dict[str, Any]:
        raise NotImplementedError

    def complete_text(self, system: str, user: str) -> str:
        raise NotImplementedError


class MockLLMClient(LLMClient):
    def complete_json(self, system: str, user: str) -> dict[str, Any]:
        lower = user.lower()
        if "session plan" in lower:
            return {
                "topic": "A practical conversation about the user's chosen topic",
                "opening_question": "What would you like to explain or practice first?",
                "follow_up_strategy": [
                    "Ask for a specific example.",
                    "Invite the learner to compare two options.",
                    "Ask a short opinion question.",
                ],
                "target_expressions": [
                    "In my experience...",
                    "One challenge is...",
                    "I would recommend...",
                ],
                "evaluation_rubric": {
                    "fluency": "Can speak in connected sentences with manageable pauses.",
                    "grammar": "Uses core tense and sentence patterns accurately enough to be understood.",
                    "vocabulary": "Uses topic-specific words and useful linking phrases.",
                    "pronunciation_pace": "Speaks at a clear pace with understandable stress.",
                },
            }
        if "evaluation" in lower:
            return {
                "fluency_feedback": "You kept the conversation moving and answered in complete ideas.",
                "grammar_feedback": "Watch subject-verb agreement and tense consistency in longer answers.",
                "vocabulary_feedback": "Add more precise topic words and linking phrases to sound more natural.",
                "pronunciation_pace_feedback": "No speech metrics were provided, so pronunciation feedback is limited.",
                "top_3_issues": [
                    "Short answers need more detail.",
                    "Some grammar patterns need cleaner tense control.",
                    "Vocabulary can be more specific to the topic.",
                ],
                "next_practice_suggestion": "Practice a two-minute answer using one example, one contrast, and one recommendation.",
            }
        return {}

    def complete_text(self, system: str, user: str) -> str:
        return "Good. Can you give me one specific example and explain why it matters?"


class AzureOpenAILLMClient(LLMClient):
    def __init__(self, settings: Settings):
        if not settings.azure_openai_endpoint or not settings.azure_openai_api_key:
            raise ValueError("Azure OpenAI endpoint and API key are required when PROVIDER=azure.")
        self.deployment = settings.azure_openai_deployment
        self.client = AzureOpenAI(
            azure_endpoint=settings.azure_openai_endpoint,
            api_key=settings.azure_openai_api_key,
            api_version=settings.azure_openai_api_version,
        )

    def complete_json(self, system: str, user: str) -> dict[str, Any]:
        response = self.client.chat.completions.create(
            model=self.deployment,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        )
        content = response.choices[0].message.content or "{}"
        return json.loads(content)

    def complete_text(self, system: str, user: str) -> str:
        response = self.client.chat.completions.create(
            model=self.deployment,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        )
        return response.choices[0].message.content or ""


def build_llm_client(settings: Settings) -> LLMClient:
    if settings.provider == "azure":
        return AzureOpenAILLMClient(settings)
    return MockLLMClient()
