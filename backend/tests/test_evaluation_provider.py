import json
from app.services.evaluation_provider import evaluate_snapshot, synthesize_session
from app.schemas import EvaluationResult


def test_azure_protocol(settings, mock_openai_post, evaluation_response):
    mock_openai_post.return_value = evaluation_response
    settings.azure_openai_endpoint += '/'
    evaluate_snapshot(json.dumps({'learner_transcripts': []}), 'text-deployment', settings)
    args, kwargs = mock_openai_post.call_args
    assert args == ('https://test-resource.openai.azure.com/openai/v1/chat/completions',)
    assert kwargs['headers'] == {'api-key': 'server-secret'}
    assert kwargs['timeout'] == 60.0
    payload = kwargs['json']
    assert payload['model'] == 'text-deployment'
    assert payload['max_completion_tokens'] == 4000
    schema = payload['response_format']['json_schema']
    assert schema['strict'] is True
    assert schema['schema']['additionalProperties'] is False
    assert set(schema['schema']['required']) == set(schema['schema']['properties'])
    assert 'server-secret' not in json.dumps(payload)
    assert 'untrusted' in payload['messages'][0]['content']
    assert "Evaluate the learner's transcript" in payload['messages'][0]['content']
    assert 'Do not infer pronunciation' in payload['messages'][0]['content']
    assert '1-3 ranked, concrete next_steps' in payload['messages'][0]['content']


def test_grounded_correction(settings, mock_openai_post, evaluation_payload):
    import httpx
    evaluation_payload['corrections'] = [{'turn_id': 'turn-1', 'original': 'I build it yesterday',
        'improved': 'I built it yesterday', 'explanation': 'Use past tense for yesterday.'}]
    mock_openai_post.return_value = httpx.Response(200,
        request=httpx.Request('POST', 'https://test.example'), json={'choices': [{
            'finish_reason': 'stop', 'message': {'content': json.dumps(evaluation_payload)}}]})
    result = evaluate_snapshot(json.dumps({'learner_transcripts': [{
        'turn_id': 'turn-1', 'text': 'I build it yesterday.'}]}), 'text', settings)
    assert result.corrections[0].turn_id == 'turn-1'


def test_supported_outcome_changes_coaching_lens(settings, mock_openai_post, evaluation_response):
    mock_openai_post.return_value = evaluation_response
    snapshot = json.dumps({'preferences': {'speaking_goal': 'Handle work conversations'},
                           'learner_transcripts': []})
    evaluate_snapshot(snapshot, 'text', settings)
    instructions = mock_openai_post.call_args.kwargs['json']['messages'][0]['content']
    assert 'professional clarity' in instructions
    assert '30% coherence' in instructions
    assert 'shared grammar, vocabulary' in instructions


def test_final_synthesis_uses_saved_components(settings, mock_openai_post,
                                               evaluation_payload, synthesis_response):
    transcript = EvaluationResult.model_validate(evaluation_payload)
    mock_openai_post.return_value = synthesis_response
    result = synthesize_session(
        transcript,
        {'overview': {'average_pronunciation': 85, 'average_spoken_fluency': 80}},
        {'speaking_goal': 'Interview practice'}, 'text', settings)
    payload = mock_openai_post.call_args.kwargs['json']
    assert payload['response_format']['json_schema']['name'] == 'session_synthesis'
    assert set(payload['response_format']['json_schema']['schema']['properties']) == {
        'summary', 'strengths', 'next_steps'}
    evidence = json.loads(payload['messages'][1]['content'])
    assert evidence['transcript_evaluation']['grammar'] == evaluation_payload['grammar']
    assert evidence['speech_findings']['overview']['average_pronunciation'] == 85
    assert result.grammar == transcript.grammar
    assert result.corrections == transcript.corrections


def test_chronological_context_reaches_provider(settings, mock_openai_post, evaluation_response):
    mock_openai_post.return_value = evaluation_response
    context = {'timeline': [
        {'role': 'agent', 'text': 'Why?', 'start_ms': 0, 'playback_status': 'interrupted'},
        {'role': 'learner', 'turn_id': 'turn-1', 'text': 'Because.', 'start_ms': 100}],
        'untimed_agent_transcripts': []}
    snapshot = json.dumps({'learner_transcripts': [], 'conversation_context': context})
    evaluate_snapshot(snapshot, 'text', settings)
    messages = mock_openai_post.call_args.kwargs['json']['messages']
    assert json.loads(messages[1]['content'])['conversation_context'] == context
    assert 'Equal timestamps and overlapping intervals' in messages[0]['content']
    assert 'Older snapshots without' in messages[0]['content']


def test_context_overflow_and_process_capacity_do_not_dispatch(settings, mock_openai_post):
    import pytest
    from app.services.evaluation_budget import ContextLimit, ProviderBusy, PROVIDER_SLOTS
    with pytest.raises(ContextLimit):
        evaluate_snapshot(json.dumps({'learner_transcripts': [], 'extra': 'X' * 40000}), 'text', settings)
    with PROVIDER_SLOTS, PROVIDER_SLOTS:
        with pytest.raises(ProviderBusy):
            evaluate_snapshot(json.dumps({'learner_transcripts': []}), 'text', settings)
    mock_openai_post.assert_not_called()
