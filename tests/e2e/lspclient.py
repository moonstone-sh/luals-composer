#!/usr/bin/env python3
"""Minimal real LSP client for driving lua-language-server headless."""
import json, os, subprocess, sys, threading, time, queue

class LSP:
    def __init__(self, cmd, root):
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, cwd=root)
        self.root = root
        self.id = 0
        self.q = queue.Queue()
        self.notes = []
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._errreader, daemon=True).start()

    def _errreader(self):
        for line in self.p.stderr:
            pass

    def _reader(self):
        f = self.p.stdout
        while True:
            headers = {}
            while True:
                line = f.readline()
                if not line:
                    self.q.put(None); return
                line = line.decode('utf8').strip()
                if line == '': break
                k, v = line.split(':', 1)
                headers[k.strip().lower()] = v.strip()
            n = int(headers.get('content-length', 0))
            body = f.read(n)
            try:
                msg = json.loads(body.decode('utf8'))
            except Exception:
                continue
            if 'id' in msg and 'method' not in msg:
                self.q.put(msg)
            else:
                self.notes.append(msg)
                # auto-answer server->client requests
                if 'id' in msg and 'method' in msg:
                    self._send({'jsonrpc':'2.0','id':msg['id'],'result':None})

    def _send(self, obj):
        b = json.dumps(obj).encode('utf8')
        self.p.stdin.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
        self.p.stdin.flush()

    def req(self, method, params, timeout=60):
        self.id += 1
        i = self.id
        self._send({'jsonrpc':'2.0','id':i,'method':method,'params':params})
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                m = self.q.get(timeout=deadline - time.time())
            except queue.Empty:
                break
            if m is None: raise RuntimeError('server exited')
            if m.get('id') == i: return m
        raise RuntimeError('timeout on ' + method)

    def note(self, method, params):
        self._send({'jsonrpc':'2.0','method':method,'params':params})

    def initialize(self):
        r = self.req('initialize', {
            'processId': os.getpid(),
            'rootUri': 'file://' + self.root,
            'workspaceFolders': [{'uri':'file://'+self.root,'name':'ws'}],
            'capabilities': {
                'textDocument': {
                    'hover': {'contentFormat':['markdown','plaintext']},
                    'completion': {'completionItem':{'snippetSupport':True}},
                    'publishDiagnostics': {},
                },
                'workspace': {'configuration': True},
            },
            'initializationOptions': {'trustByClient': True},
        })
        self.note('initialized', {})
        return r

    def open(self, path, langid='lua'):
        with open(path) as fh: text = fh.read()
        uri = 'file://' + path
        self.note('textDocument/didOpen', {'textDocument':{
            'uri':uri,'languageId':langid,'version':1,'text':text}})
        return uri

    def hover(self, uri, line, char):
        return self.req('textDocument/hover', {
            'textDocument':{'uri':uri},'position':{'line':line,'character':char}})

    def completion(self, uri, line, char):
        return self.req('textDocument/completion', {
            'textDocument':{'uri':uri},'position':{'line':line,'character':char}})

    def diags(self, uri):
        return [n for n in self.notes
                if n.get('method')=='textDocument/publishDiagnostics'
                and n['params']['uri']==uri]

    def shutdown(self):
        try:
            self.req('shutdown', None, timeout=5)
            self.note('exit', None)
        except Exception:
            pass
        try: self.p.kill()
        except Exception: pass
