#!/usr/bin/env python3
"""Submit CORDIS definitions to an isolated semantic-service test instance."""

import argparse
import json
import os
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


API = '/api/semantic/v1/ontology/define'
HERE = Path(__file__).resolve().parent
DEFAULT_FILES = [HERE / 'cordis_eval.json', HERE / 'cordis_eval_org.json']


def call(base, path, body=None):
    headers = {'Accept': 'application/json'}
    if body is not None:
        headers['Content-Type'] = 'application/json'
    authorization = os.environ.get('SEMANTIC_TEST_AUTHORIZATION')
    if authorization:
        headers['Authorization'] = authorization
    request = Request(base + API + path, body, headers)
    try:
        with urlopen(request, timeout=120) as response:
            result = json.load(response)
    except HTTPError as error:
        message = error.read(1000).decode('utf-8', errors='replace')
        raise RuntimeError(f'{path} HTTP {error.code}: {message}') from error
    if result.get('code') != 200:
        raise RuntimeError(f'{path} 接口返回 {result.get("code")}: {result.get("message")}')
    return result.get('data')


def main():
    parser = argparse.ArgumentParser(description='通过本体 API 上传并核验 CORDIS 测试定义')
    parser.add_argument('--base-url', required=True, help='独立测试 semantic-service 的地址，包含协议和端口')
    parser.add_argument('--with-cordis-baseline', action='store_true', help='先上传四个 CORDIS 分域，再上传两个主测本体')
    parser.add_argument('files', nargs='*', type=Path, help='可显式指定待上传 JSON，用于只上传单个场景')
    args = parser.parse_args()
    base = args.base_url.rstrip('/')
    target = urlsplit(base)
    if (target.scheme not in ('http', 'https') or not target.netloc or target.path
            or target.username or target.query or target.fragment):
        parser.error('--base-url 应形如 http://测试主机:端口')
    files = args.files or DEFAULT_FILES
    if args.with_cordis_baseline:
        files = sorted((HERE / 'cordis-baseline').glob('*.json')) + files

    models = {}
    try:
        for file in files:
            payload = file.read_bytes()
            ((scene, definition),) = json.loads(payload).items()
            if scene in models:
                raise ValueError(f'重复的场景 {scene}')
            models[scene] = (payload, definition)

        existing = set(call(base, '/scenes') or [])
        conflicts = existing.intersection(models)
        if conflicts:
            raise ValueError('目标已有同名本体，请选空白场景或仅指定尚未上传的文件。' + '、'.join(sorted(conflicts)))

        for scene, (payload, definition) in models.items():
            call(base, '/upload/json', payload)
            query = '?' + urlencode({'scene_name': scene})
            actual = set(call(base, '/object_list' + query) or [])
            expected = {item['api_name'] for item in definition['entities'] + definition['relations']}
            if actual != expected:
                raise RuntimeError(f'{scene} 对象名核对失败。缺少 {sorted(expected-actual)}，额外 {sorted(actual-expected)}')
            print(f'{scene} 上传已核对，{len(definition["entities"])} 实体 / {len(definition["relations"])} 关系')
    except (OSError, URLError, ValueError, RuntimeError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
