"""Synchronous evaluation with durable status and explicit retry."""
import json
import sqlite3
from urllib.parse import urlsplit
import httpx
from fastapi import HTTPException
from app.services.pronunciation import assess_snapshot, speech_context
from app.services.evaluation_provider import evaluate_snapshot
from app.storage.evaluations import evaluation_record, finish_evaluation


def get_evaluation(settings, session_id):
    try:
        outcome, record, _ = evaluation_record(settings.database_path, session_id)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, 'Evaluation storage is unavailable.') from None
    if outcome == 'not_found':
        raise HTTPException(404, 'Session or evaluation not found.')
    return record


def run_evaluation(settings, session_id):
    # Completed results remain available without provider configuration.
    try:
        existing = get_evaluation(settings, session_id)
    except HTTPException as error:
        if error.status_code != 404:
            raise
    else:
        if existing.status == 'completed':
            return existing, 200
    try:
        endpoint = urlsplit(settings.azure_openai_endpoint)
        valid = (endpoint.scheme == 'https' and endpoint.hostname and not endpoint.username
                 and not endpoint.password and not endpoint.query and not endpoint.fragment
                 and endpoint.path in ('', '/'))
    except ValueError:
        valid = False
    if (not valid or not settings.azure_openai_api_key.get_secret_value()
            or not settings.azure_openai_evaluation_deployment.strip()):
        raise HTTPException(503, 'Azure evaluation is not configured correctly.')
    try:
        outcome, record, snapshot = evaluation_record(
            settings.database_path, session_id, settings.azure_openai_evaluation_deployment)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, 'Evaluation storage is unavailable.') from None
    errors = {'not_found': (404, 'Session not found.'),
              'not_ready': (409, 'Session data is not ready for evaluation.'),
              'too_large': (413, 'Evaluation input exceeds 200000 bytes.')}
    if outcome in errors:
        raise HTTPException(*errors[outcome])
    if outcome == 'running':
        raise HTTPException(409, 'Evaluation is running.', headers={'Retry-After': '5'})
    if outcome == 'existing':
        return record, 200
    result, failure, code = None, None, None
    speech_assessments = []
    message = None
    try:
        speech_assessments = assess_snapshot(snapshot, session_id, settings)
        model_snapshot = snapshot
        if speech_assessments:
            model_input = json.loads(snapshot)
            model_input['speech_findings'] = speech_context(speech_assessments)
            model_snapshot = json.dumps(model_input, ensure_ascii=False)
        result = evaluate_snapshot(model_snapshot, record.deployment, settings)
    except HTTPException as error:
        code, message = error.status_code, error.detail
        failure = {422: 'invalid_audio', 413: 'audio_too_large', 503: 'speech_unavailable',
                   504: 'speech_timeout'}.get(code, 'speech_failure')
    except (httpx.HTTPError, ValueError, KeyError, TypeError, IndexError) as error:
        failure = 'provider_timeout' if isinstance(error, httpx.TimeoutException) else 'provider_failure'
        code = 504 if failure == 'provider_timeout' else 502
    try:
        completed = finish_evaluation(settings.database_path, record, result, failure, speech_assessments)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, 'Evaluation storage is unavailable.') from None
    if completed is None:
        raise HTTPException(409, 'Evaluation attempt was superseded.')
    if failure:
        raise HTTPException(code, message or ('Evaluation provider timed out.' if code == 504
                            else 'Evaluation provider could not evaluate this session.'))
    return completed, 201
