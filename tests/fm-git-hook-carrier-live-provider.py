#!/usr/bin/env python3
"""Private scripted model provider for the Git hook carrier live guard.

Usage: fm-git-hook-carrier-live-provider.py <lab-dir>

Serves the Anthropic Messages API (/v1/messages) and the OpenAI Responses API
(/v1/responses). Writes the bound port to <lab-dir>/port and appends a summary
of every request to <lab-dir>/requests.jsonl. A request that offers a shell
tool (Bash, or bash) and carries no tool result yet is answered with one call
of that tool running the command in <lab-dir>/command; a request carrying that
tool's result, and any side request without a shell tool, is answered with a
short end-of-turn text. No model is called and nothing leaves the loopback
interface.
"""
import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lab = pathlib.Path(sys.argv[1])


def has_tool_result(body):
    for message in body.get('messages', []):
        content = message.get('content')
        if isinstance(content, list) and any(part.get('type') == 'tool_result' for part in content if isinstance(part, dict)):
            return True
    return False


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply_json(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply_json({}, 404)

    def openai_responses(self, body):
        items = body.get('input', [])
        done = any(isinstance(i, dict) and i.get('type') == 'function_call_output' for i in items)
        tool = next((t for t in body.get('tools', []) if t.get('name') == 'bash'), None)
        with (lab / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'path': self.path, 'tools': [t.get('name') for t in body.get('tools', [])],
                                  'tool_result': done}) + '\n')
        if tool is not None and not done:
            args = json.dumps({'command': (lab / 'command').read_text().strip()})
            item = {'type': 'function_call', 'id': 'fc_fm_carrier', 'call_id': 'call_fm_carrier',
                    'name': 'bash', 'arguments': args, 'status': 'completed'}
        else:
            item = {'type': 'message', 'id': 'm_fm_carrier', 'role': 'assistant', 'status': 'completed',
                    'content': [{'type': 'output_text', 'text': 'carrier probe finished', 'annotations': []}]}
        events = [{'type': 'response.created', 'response': {'id': 'r_fm_carrier', 'status': 'in_progress'}},
                  {'type': 'response.output_item.added', 'output_index': 0,
                   'item': dict(item, status='in_progress', **({'arguments': ''} if item['type'] == 'function_call' else {'content': []}))}]
        if item['type'] == 'function_call':
            events += [{'type': 'response.function_call_arguments.delta', 'output_index': 0, 'item_id': item['id'], 'delta': item['arguments']},
                       {'type': 'response.function_call_arguments.done', 'output_index': 0, 'item_id': item['id'], 'arguments': item['arguments']}]
        else:
            events += [{'type': 'response.content_part.added', 'output_index': 0, 'item_id': item['id'], 'content_index': 0,
                        'part': {'type': 'output_text', 'text': ''}},
                       {'type': 'response.output_text.delta', 'output_index': 0, 'item_id': item['id'], 'content_index': 0,
                        'delta': 'carrier probe finished'}]
        events += [{'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                   {'type': 'response.completed', 'response': {'id': 'r_fm_carrier', 'status': 'completed', 'output': [item],
                                                              'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}}]
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for value in events:
            self.wfile.write(('data: ' + json.dumps(value) + '\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n')
        self.wfile.flush()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        if self.path.split('?')[0].endswith('/responses'):
            return self.openai_responses(body)
        with (lab / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'path': self.path, 'tools': [t.get('name') for t in body.get('tools', [])],
                                  'tool_result': has_tool_result(body)}) + '\n')
        if self.path.split('?')[0].endswith('/messages/count_tokens'):
            return self.reply_json({'input_tokens': 1})
        if not self.path.split('?')[0].endswith('/messages'):
            return self.reply_json({'error': {'type': 'not_found', 'message': 'not served'}}, 404)
        bash = next((t for t in body.get('tools', []) if t.get('name') == 'Bash'), None)
        if bash is not None and not has_tool_result(body):
            command = (lab / 'command').read_text().strip()
            block = {'type': 'tool_use', 'id': 'toolu_fm_carrier', 'name': 'Bash',
                     'input': {'command': command, 'description': 'Run the carrier probe'}}
            stop = 'tool_use'
        else:
            block = {'type': 'text', 'text': 'carrier probe finished'}
            stop = 'end_turn'
        message = {'id': 'msg_fm_carrier', 'type': 'message', 'role': 'assistant',
                   'model': body.get('model', 'claude'), 'content': [], 'stop_reason': None,
                   'stop_sequence': None, 'usage': {'input_tokens': 1, 'output_tokens': 1}}
        if not body.get('stream'):
            message.update(content=[block], stop_reason=stop)
            return self.reply_json(message)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()

        def event(name, value):
            self.wfile.write(('event: ' + name + '\ndata: ' + json.dumps(value) + '\n\n').encode())

        event('message_start', {'type': 'message_start', 'message': message})
        if block['type'] == 'tool_use':
            event('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': dict(block, input={})})
            event('content_block_delta', {'type': 'content_block_delta', 'index': 0,
                                          'delta': {'type': 'input_json_delta', 'partial_json': json.dumps(block['input'])}})
        else:
            event('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
            event('content_block_delta', {'type': 'content_block_delta', 'index': 0,
                                          'delta': {'type': 'text_delta', 'text': block['text']}})
        event('content_block_stop', {'type': 'content_block_stop', 'index': 0})
        event('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': stop, 'stop_sequence': None},
                                'usage': {'output_tokens': 1}})
        event('message_stop', {'type': 'message_stop'})
        self.wfile.flush()


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(lab / 'port').write_text(str(server.server_address[1]))
server.serve_forever()
