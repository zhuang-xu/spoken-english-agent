"""The shared API and Azure packages must work with or without the browser client."""
import os
from pathlib import Path
import subprocess
import sys
from zipfile import ZipFile

import pytest


def test_core_api_has_no_browser_routes(client):
    api, _ = client
    assert api.get('/practice').status_code == 404
    assert api.get('/practice-assets/practice.mjs').status_code == 404
    assert api.get('/health').status_code == 200


@pytest.mark.parametrize('level', ['function', 'anonymous'])
def test_function_auth_level_is_explicit(level):
    env = os.environ.copy()
    env['FUNCTIONS_HTTP_AUTH_LEVEL'] = level
    env['PYTHONPATH'] = str(Path(__file__).resolve().parents[1])
    subprocess.run([sys.executable, '-c', '''
import os
import function_app
http = next(f for f in function_app.app.get_functions()
            if f.get_function_name() == 'http_app_func')
assert http.get_bindings_dict()['bindings'][0]['authLevel'].value == os.environ['FUNCTIONS_HTTP_AUTH_LEVEL']
'''], env=env, capture_output=True, check=True)


@pytest.mark.parametrize('include_browser', [False, True])
def test_azure_archive_runs_independently(tmp_path, include_browser):
    root = Path(__file__).resolve().parents[2]
    archive = tmp_path / 'release.zip'
    command = [sys.executable, str(root / 'scripts/package_backend.py'), str(archive)]
    if include_browser:
        command.append('--include-browser')
    subprocess.run(command, check=True, capture_output=True)
    extracted = tmp_path / 'isolated'
    with ZipFile(archive) as package:
        names = package.namelist()
        assert {'function_app.py', 'web_app.py', 'host.json', 'requirements.txt', 'app/main.py'} <= set(names)
        assert ('browser/public/index.html' in names) == include_browser
        assert not any('tests/' in name or '__pycache__' in name or '.env' in name for name in names)
        package.extractall(extracted)
    env = os.environ.copy()
    env.pop('PYTHONPATH', None)
    subprocess.run([sys.executable, '-c', f'''
from fastapi.testclient import TestClient
import function_app
from web_app import app
with TestClient(app) as client:
    assert client.get('/health').status_code == 200
    assert client.get('/openapi.json').status_code == 200
    assert client.get('/practice').status_code == {200 if include_browser else 404}
    assert client.get('/practice-assets/realtime.mjs').status_code == {200 if include_browser else 404}
assert len(function_app.app.get_functions()) == 2
'''], cwd=extracted, env=env, capture_output=True, check=True)
