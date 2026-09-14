import json
from app.services.evaluation_provider import evaluate_snapshot


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
    assert 'one coherent English coaching report' in payload['messages'][0]['content']
    assert 'Do not produce a separate pronunciation report' in payload['messages'][0]['content']
    assert '1-3 ranked next_steps' in payload['messages'][0]['content']


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
