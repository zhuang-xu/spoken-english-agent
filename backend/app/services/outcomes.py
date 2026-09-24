"""Supported speaking outcomes and the behavior each one should change."""

OUTCOMES = {
    "Speak more fluently": {
        "conversation": "Use open questions that invite connected answers and gentle follow-ups. Encourage the learner to keep going without interrupting for corrections.",
        "evaluation": "Prioritize continuity, pacing, linking language, and recovery when a word is missing. Weight outcome progress 40% fluency, 25% coherence, 15% vocabulary, 10% grammar, and 10% pronunciation.",
    },
    "Explain ideas clearly": {
        "conversation": "Ask the learner to explain a process or idea, give a concrete example, compare alternatives, and summarize their main point.",
        "evaluation": "Prioritize structure, examples, signposting, and whether the central idea is easy to follow. Weight outcome progress 45% coherence, 20% vocabulary, 15% comprehension, 10% grammar, and 10% fluency.",
    },
    "Speak with less hesitation": {
        "conversation": "Use approachable questions that support quick responses, then gradually ask for longer answers. Do not interrupt pauses or finish sentences for the learner.",
        "evaluation": "Prioritize response readiness, reduced disruptive pausing, self-repair, and confidence-preserving strategies. Weight outcome progress 45% fluency, 20% coherence, 15% comprehension, 10% vocabulary, and 10% pronunciation.",
    },
    "Improve pronunciation": {
        "conversation": "Elicit varied everyday words and several complete sentences that provide useful pronunciation evidence. Never ask the learner to repeat isolated words as a test.",
        "evaluation": "Prioritize measured intelligibility, pronunciation accuracy, rhythm, and prosody when speech evidence exists. Weight outcome progress 50% pronunciation, 25% fluency, 10% comprehension, 10% vocabulary, and 5% grammar; do not infer acoustic qualities from text.",
    },
    "Handle work conversations": {
        "conversation": "Create a realistic work exchange that requires an update, clarification, opinion, or next-step agreement. Ask follow-ups like a supportive colleague.",
        "evaluation": "Prioritize task completion, professional clarity, appropriate vocabulary, clarification, and concise next steps. Weight outcome progress 30% coherence, 25% vocabulary, 20% comprehension, 15% fluency, and 10% grammar.",
    },
    "Handle everyday conversations": {
        "conversation": "Create a realistic daily-life exchange that requires both sharing information and responding to the other speaker. Include a natural follow-up or small change of plan.",
        "evaluation": "Prioritize successful interaction, relevant responses, natural everyday vocabulary, and repair or clarification. Weight outcome progress 25% comprehension, 25% fluency, 20% vocabulary, 20% coherence, and 10% grammar.",
    },
}


def outcome_guidance(value: str, kind: str) -> str:
    """Return guidance only for an exact supported value; user text never becomes instruction."""
    return OUTCOMES.get(value, {}).get(kind, "")
