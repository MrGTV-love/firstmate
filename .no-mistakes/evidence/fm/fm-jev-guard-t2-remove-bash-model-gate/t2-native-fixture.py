#!/usr/bin/env python3
import json
import pathlib
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lab = pathlib.Path(sys.argv[1])
backend = sys.argv[2]
turn = 0


def send_json(handler, value, status=200):
    data = json.dumps(value).encode()
    handler.send_response(status)
    handler.send_header('Content-Type', 'application/json')
    handler.send_header('Content-Length', str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        global turn
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        if self.path.endswith('/messages/count_tokens'):
            return send_json(self, {'input_tokens': 1})
        if self.path == '/v1/systemone':
            with (lab / 'jev.jsonl').open('a') as log:
                log.write(json.dumps(body) + '\n')
            scenario = json.loads((lab / 'scenario.json').read_text())
            if scenario['phase'] == 'provider':
                return send_json(self, {'error': 'synthetic outage'}, 402)
            if scenario.get('judge_delay') and 'path' in body['state']:
                time.sleep(scenario['judge_delay'])
            answers = {}
            for key, question in body['questions'].items():
                if question['type'] == 'noul':
                    answers[key] = {'type': 'noul', 'noul': 0.0 if scenario.get('benign') else 0.99}
                else:
                    choices = list(question['criteria'])
                    pick = 'irreversible' if 'irreversible' in choices and not scenario.get('benign') else choices[0]
                    answers[key] = {'type': 'choice', 'choice': pick, 'confidence': 1,
                                    'probabilities': {k: int(k == pick) for k in choices}}
            return send_json(self, {'model': 'jev-local', 'answers': answers,
                                    'usage': {'input_tokens': 1, 'output_tokens': 1}})
        if self.path == '/reset':
            turn = 0
            return send_json(self, {})
        with (lab / 'model.jsonl').open('a') as log:
            log.write(json.dumps(body) + '\n')
        turn += 1
        scenario = json.loads((lab / 'scenario.json').read_text())
        tools = body.get('tools', [])
        wanted = scenario.get('tool', 'read')
        tool = next((t for t in tools if t.get('name', '').lower() == wanted), None)
        if turn == 1 and not tool:
            return send_json(self, {'error': {'message': f'native {wanted} tool absent'}}, 400)
        args = scenario.get('args') or {'path': scenario['path'] + ':raw', 'i': 'Reading synthetic instruction'}
        if backend == 'claude' or self.path.startswith('/v1/messages'):
            args = scenario.get('args') or {'file_path': scenario['path']}
            if turn == 1:
                content = [{'type': 'tool_use', 'id': 'tool_native_read', 'name': tool['name'], 'input': args}]
            else:
                content = [{'type': 'text', 'text': 'native-context-consumed'}]
            message = {'id': 'msg_native', 'type': 'message', 'role': 'assistant',
                       'model': body['model'], 'content': [], 'stop_reason': None,
                       'stop_sequence': None, 'usage': {'input_tokens': 1, 'output_tokens': 1}}
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            def event(name, value):
                self.wfile.write(('event: ' + name + '\ndata: ' + json.dumps(value) + '\n\n').encode())
            event('message_start', {'type': 'message_start', 'message': message})
            part = content[0]
            event('content_block_start', {'type': 'content_block_start', 'index': 0,
                                         'content_block': dict(part, input={}) if turn == 1 else dict(part, text='')})
            delta = {'type': 'input_json_delta', 'partial_json': json.dumps(args)} if turn == 1 else {'type': 'text_delta', 'text': part['text']}
            event('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': delta})
            event('content_block_stop', {'type': 'content_block_stop', 'index': 0})
            event('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'tool_use' if turn == 1 else 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 1}})
            event('message_stop', {'type': 'message_stop'})
        else:
            if turn == 1:
                item = {'type': 'function_call', 'id': 'fc_native', 'call_id': 'call_native',
                        'name': tool['name'], 'arguments': json.dumps(args), 'status': 'completed'}
            else:
                item = {'type': 'message', 'id': 'm_native', 'role': 'assistant', 'status': 'completed',
                        'content': [{'type': 'output_text', 'text': 'native-context-consumed'}]}
            events = [
                {'type': 'response.created', 'response': {'id': 'r_native', 'status': 'in_progress'}},
                {'type': 'response.output_item.added', 'output_index': 0, 'item': dict(item, status='in_progress', **({'arguments': ''} if turn == 1 else {'content': []}))},
            ]
            if turn == 1:
                events.extend([
                    {'type': 'response.function_call_arguments.delta', 'output_index': 0, 'item_id': 'fc_native', 'delta': json.dumps(args)},
                    {'type': 'response.function_call_arguments.done', 'output_index': 0, 'item_id': 'fc_native', 'arguments': json.dumps(args)},
                ])
            else:
                events.extend([
                    {'type': 'response.content_part.added', 'output_index': 0, 'item_id': 'm_native', 'content_index': 0, 'part': {'type': 'output_text', 'text': ''}},
                    {'type': 'response.output_text.delta', 'output_index': 0, 'item_id': 'm_native', 'content_index': 0, 'delta': 'native-context-consumed'},
                ])
            events.extend([
                {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                {'type': 'response.completed', 'response': {'id': 'r_native', 'status': 'completed', 'output': [item], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}},
            ])
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            for value in events:
                self.wfile.write(('data: ' + json.dumps(value) + '\n\n').encode())
            self.wfile.write(b'data: [DONE]\n\n')
        self.wfile.flush()


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(lab / 'port').write_text(str(server.server_address[1]))
server.serve_forever()
