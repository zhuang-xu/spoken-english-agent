"""Synchronous evaluation with durable status and explicit retry."""
import json
import sqlite3
from urllib.parse import urlsplit
import httpx
from fastapi import HTTPException
from app.services.pronunciation import snapshot_assessment_state, speech_context, summarize_speech
from app.services.evaluation_provider import evaluate_snapshot, synthesize_session
from app.storage.evaluations import (evaluation_record, finish_evaluation,
                                     save_transcript_evaluation, wait_for_speech)


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
    result, failure, code, message = None, None, None, None
    transcript_result = record.transcript_result
    if transcript_result is None:
        try:
            transcript_result = evaluate_snapshot(snapshot, record.deployment, settings)
            record = save_transcript_evaluation(settings.database_path, record, transcript_result)
            if record is None:
                raise HTTPException(409, 'Evaluation attempt was superseded.')
        except HTTPException:
            raise
        except (sqlite3.Error, OSError):
            raise HTTPException(503, 'Evaluation storage is unavailable.') from None
        except (httpx.HTTPError, ValueError, KeyError, TypeError, IndexError) as error:
            failure = ('transcript_provider_timeout' if isinstance(error, httpx.TimeoutException)
                       else 'transcript_provider_failure')
            code = 504 if isinstance(error, httpx.TimeoutException) else 502
            try:
                completed = finish_evaluation(
                    settings.database_path, record, error_code=failure,
                    failure_stage='transcript')
            except (sqlite3.Error, OSError):
                raise HTTPException(503, 'Evaluation storage is unavailable.') from None
            if completed is None:
                raise HTTPException(409, 'Evaluation attempt was superseded.')
            raise HTTPException(code, 'Transcript evaluation provider timed out.' if code == 504
                                else 'Transcript evaluation provider could not evaluate this session.')

    try:
        speech_assessments, pending_turn_ids = snapshot_assessment_state(
            snapshot, session_id, settings)
    except HTTPException as error:
        code, message, failure = error.status_code, error.detail, 'speech_failure'
        pending_turn_ids = []
        speech_assessments = []
    speech_summary = summarize_speech(speech_assessments)
    if not failure and pending_turn_ids:
        try:
            waiting = wait_for_speech(
                settings.database_path, record, speech_assessments, speech_summary,
                pending_turn_ids)
        except (sqlite3.Error, OSError):
            raise HTTPException(503, 'Evaluation storage is unavailable.') from None
        if waiting is None:
            raise HTTPException(409, 'Evaluation attempt was superseded.')
        return waiting, 202

    if not failure:
        assessed = any(item.status == 'assessed' for item in speech_assessments)
        try:
            if assessed:
                source = json.loads(snapshot)
                result = synthesize_session(
                    transcript_result, speech_context(speech_assessments),
                    source.get('preferences', {}), record.deployment, settings)
            else:
                result = transcript_result
            record = record.model_copy(update={
                'transcript_status': 'completed', 'transcript_result': transcript_result,
                'speech_status': ('not_assessed' if not speech_assessments else
                                  'partial' if any(a.status == 'unavailable' for a in speech_assessments)
                                  else 'completed'),
                'final_status': 'running',
            })
        except (httpx.HTTPError, ValueError, KeyError, TypeError, IndexError) as error:
            failure = ('final_provider_timeout' if isinstance(error, httpx.TimeoutException)
                       else 'final_provider_failure')
            code = 504 if isinstance(error, httpx.TimeoutException) else 502
    try:
        completed = finish_evaluation(
            settings.database_path, record, result, failure, speech_assessments,
            speech_summary)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, 'Evaluation storage is unavailable.') from None
    if completed is None:
        raise HTTPException(409, 'Evaluation attempt was superseded.')
    if failure:
        raise HTTPException(code, message or ('Final evaluation provider timed out.' if code == 504
                            else 'Final evaluation provider could not evaluate this session.'))
    return completed, 201
