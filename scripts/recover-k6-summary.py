#!/usr/bin/env python3
"""Validate a k6 summary or recover a full summary from Kubernetes pod logs."""
import argparse
import json
from pathlib import Path

BEGIN = '__DIPLOMA_K6_JSON_BEGIN__'
PART = '__DIPLOMA_K6_JSON_CHUNK__'
END = '__DIPLOMA_K6_JSON_END__'


def validate(data):
    if not isinstance(data, dict):
        raise ValueError('Summary is not a JSON object')
    if not isinstance(data.get('metrics'), dict):
        raise ValueError('Summary lacks k6 metrics')
    if not isinstance(data.get('diploma'), dict):
        raise ValueError('Summary lacks diploma run metadata')
    if not data['diploma'].get('model'):
        raise ValueError('Summary has no benchmark model')
    return data


def extract(log_text):
    chunks = []
    active = False
    recovered = None
    for line in log_text.splitlines():
        line = line.rstrip('\r\n')
        if line == BEGIN:
            active = True
            chunks = []
        elif line == END and active:
            recovered = validate(json.loads(''.join(chunks)))
            active = False
        elif line.startswith(PART) and active:
            chunks.append(line[len(PART):])
    if recovered is None:
        raise ValueError('No complete diploma k6 JSON block found in pod logs')
    return recovered


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--validate', type=Path, metavar='SUMMARY_JSON')
    source.add_argument('--logs', type=Path, metavar='K6_LOG')
    parser.add_argument('--output', type=Path, help='Recovered JSON destination')
    args = parser.parse_args()
    if args.validate:
        validate(json.loads(args.validate.read_text(encoding='utf-8')))
        print('Summary JSON verified')
    else:
        if args.output is None:
            parser.error('--output is required with --logs')
        result = extract(args.logs.read_text(encoding='utf-8', errors='replace'))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temp_file = args.output.with_name(args.output.name + '.partial')
        temp_file.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        temp_file.replace(args.output)
        print('Recovered summary JSON from Kubernetes logs')


if __name__ == '__main__':
    main()
