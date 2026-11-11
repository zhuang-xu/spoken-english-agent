"""Synchronous evaluation with durable status and explicit retry."""
import json
from app.services.evaluation_batches import BatchPending, WorkLimit, reserve_synthesis_call
from app.services.evaluation_budget import ContextLimit, ProviderBusy
import sqlite3
from urllib.parse import urlsplit
import httpx
from fastapi import HTTPException
from app.services.pronunciation import snapshot_assessment_state, speech_context, summarize_speech
from app.services.evaluation_provider import evaluate_snapshot, synthesize_session
from app.storage.evaluations import (evaluation_record, finish_evaluation,
                                     save_transcript_evaluation, wait_for_speech, wait_for_transcript)


def get_evaluation(settings, session_id, account_id):
    try:
        outcome, record, _ = evaluation_record(settings.storage_path, session_id, account_id)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, 'Evaluation storage is unavailable.') from None
    if outcome == 'not_found':
        raise HTTPException(404, 'Session or evaluation not found.')
    return record


def run_evaluation(settings, session_id, account_id):
    # Completed results remain available without provider configuration.
    try:
        existing = get_evaluation(settings, session_id, account_id)
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
            settings.storage_path, session_id, account_id, settings.azure_openai_evaluation_deployment)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, 'Evaluation storage is unavailable.') from None
    errors = {'not_found': (404, 'Session not found.'),
              'not_ready': (409, 'Session data is not ready for evaluation.'),
              'too_large': (413, 'Evaluation input exceeds 10 MiB.')}
    if outcome in errors:
        raise HTTPException(*errors[outcome])
    if outcome == 'running':
        raise HTTPException(409, 'Evaluation is running.', headers={'Retry-After': '5'})
    if outcome == 'existing':
        return record, 200
    result, failure, code, message = None, None, None, None
    transcript_result = record.transcript_result
    incremental_transcript = False
    if transcript_result is None:
        try:
            from app.services.evaluation_batches import advance, TRIGGER_BYTES
            from app.services.evaluation_budget import encoded, fits
            from app.services.evaluation_provider import INSTRUCTIONS, provider_schema
            from app.schemas import EvaluationResult
            source = json.loads(snapshot)
            canonical = {k: v for k, v in source.items() if k != 'conversation_context'}
            if (len(encoded(canonical).encode()) >= TRIGGER_BYTES or
                    not fits(snapshot, INSTRUCTIONS, provider_schema(EvaluationResult),
                             settings.evaluation_context_capacity)):
                # Preserve the deployment recorded by the immutable reservation.
                batch_settings = settings.model_copy(update={
                    'azure_openai_evaluation_deployment': record.deployment})
                incremental_transcript = True
                transcript_result = advance(batch_settings, session_id, source, final=True)
            else:
                transcript_result = evaluate_snapshot(snapshot, record.deployment, settings)
            record = save_transcript_evaluation(settings.storage_path, record, transcript_result)
            if record is None:
                raise HTTPException(409, 'Evaluation attempt was superseded.')
        except BatchPending as pending:
            try:
                waiting = wait_for_transcript(settings.storage_path, record, pending.total, pending.completed)
            except (sqlite3.Error, OSError):
                raise HTTPException(503, 'Evaluation storage is unavailable.') from None
            if waiting is None:
                raise HTTPException(409, 'Evaluation attempt was superseded.')
            return waiting, 202
        except HTTPException:
            raise
        except (sqlite3.Error, OSError):
            raise HTTPException(503, 'Evaluation storage is unavailable.') from None
        except (httpx.HTTPError, ValueError, KeyError, TypeError, IndexError) as error:
            failure = ('evaluation_provider_busy' if isinstance(error, ProviderBusy) else
                       'evaluation_work_limit_exceeded' if isinstance(error, WorkLimit) else
                       'evaluation_context_capacity' if isinstance(error, ContextLimit) else
                       'transcript_provider_timeout' if isinstance(error, httpx.TimeoutException)
                       else 'transcript_provider_failure')
            code = (422 if isinstance(error, WorkLimit) else
                    503 if isinstance(error, (ContextLimit, ProviderBusy)) else
                    504 if isinstance(error, httpx.TimeoutException) else 502)
            try:
                completed = finish_evaluation(
                    settings.storage_path, record, error_code=failure,
                    failure_stage='transcript')
            except (sqlite3.Error, OSError):
                raise HTTPException(503, 'Evaluation storage is unavailable.') from None
            if completed is None:
                raise HTTPException(409, 'Evaluation attempt was superseded.')
            raise HTTPException(code, failure if code in (422, 503) else
                                'Transcript evaluation provider timed out.' if code == 504
                                else 'Transcript evaluation provider could not evaluate this session.')

    if incremental_transcript:
        try:
            waiting = wait_for_transcript(settings.storage_path, record,
                                          record.transcript_windows_total, record.transcript_windows_total)
        except (sqlite3.Error, OSError):
            raise HTTPException(503, 'Evaluation storage is unavailable.') from None
        if waiting is None:
            raise HTTPException(409, 'Evaluation attempt was superseded.')
        return waiting, 202

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
                settings.storage_path, record, speech_assessments, speech_summary,
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
                reserve_synthesis_call(settings, session_id)
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
        except (sqlite3.Error, OSError):
            raise HTTPException(503, 'Evaluation storage is unavailable.') from None
        except (httpx.HTTPError, ValueError, KeyError, TypeError, IndexError) as error:
            failure = ('evaluation_work_limit_exceeded' if isinstance(error, WorkLimit) else
                       'final_provider_timeout' if isinstance(error, httpx.TimeoutException)
                       else 'final_provider_failure')
            code = (422 if isinstance(error, WorkLimit) else
                    503 if isinstance(error, (ContextLimit, ProviderBusy)) else
                    504 if isinstance(error, httpx.TimeoutException) else 502)
    try:
        completed = finish_evaluation(
            settings.storage_path, record, result, failure, speech_assessments,
            speech_summary)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, 'Evaluation storage is unavailable.') from None
    if completed is None:
        raise HTTPException(409, 'Evaluation attempt was superseded.')
    if failure:
        raise HTTPException(code, message or ('evaluation_work_limit_exceeded' if code == 422 else
                                            'Final evaluation provider timed out.' if code == 504
                            else 'Final evaluation provider could not evaluate this session.'))
    return completed, 201
