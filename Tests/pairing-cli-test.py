# Exercises only a temporary-root helper with stub provider CLIs and a random TLS port.
# Usage: python3 Tests/pairing-cli-test.py /path/to/built/iris-bridge
import fcntl, json, os, pathlib, pty, re, select, socket, ssl, struct, subprocess, sys, tempfile, termios, time, urllib.request
binary=str(pathlib.Path(sys.argv[1]).resolve()) if len(sys.argv)>1 else '/tmp/iris-bridge-build/debug/iris-bridge'
stubs=pathlib.Path(__file__).resolve().parent/'stubs'
with tempfile.TemporaryDirectory(prefix='iris-pairing-cli-') as tmp:
 root=pathlib.Path(tmp)
 (root/'.local/bin').mkdir(parents=True)
 for provider in ['claude','codex']: (root/'.local/bin'/provider).symlink_to(stubs/provider)
 env=dict(os.environ,CFFIXED_USER_HOME=tmp,PATH=str(stubs)+':'+os.environ['PATH'])
 with socket.socket() as s:
  s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
 assert port!=48731
 with (root/'serve.log').open('w') as log:
  server=subprocess.Popen([binary,'serve','--root',tmp,'--port',str(port),'--no-bonjour'],stdout=log,stderr=log,env=env)
  try:
   context=ssl._create_unverified_context()
   for _ in range(50):
    try:
     urllib.request.urlopen(f'https://127.0.0.1:{port}/status',context=context,timeout=.2).read(); break
    except Exception: time.sleep(.1)
   else: raise RuntimeError('scratch helper did not start')
   def tty(columns):
    master,slave=pty.openpty(); fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',50,columns,0,0))
    child=subprocess.Popen([binary,'pair','--root',tmp,'--port',str(port)],stdin=subprocess.DEVNULL,stdout=slave,stderr=slave,env=env); os.close(slave)
    output=b''; end=time.time()+10
    while time.time()<end:
     if select.select([master],[],[],.1)[0]:
      try: chunk=os.read(master,65536)
      except OSError: break
      if not chunk: break
      output+=chunk
     elif child.poll() is not None: break
    if child.poll() is None: child.kill()
    os.close(master); assert child.wait()==0
    return output.decode()
   narrow=tty(20)
   assert 'Widen Terminal to at least' in narrow and '\x1b[30;47m' not in narrow
   wide=tty(160)
   assert '\x1b[30;47m' in wide and 'Scan this QR code' in wide
   fallback=subprocess.run([binary,'pair','--code-only','--root',tmp,'--port',str(port)],capture_output=True,text=True,env=env,timeout=5)
   assert fallback.returncode==0 and re.search(r'Pairing code:\s+[0-9]{6}',fallback.stdout)
   headless=subprocess.run([binary,'pair','--root',tmp,'--port',str(port)],capture_output=True,text=True,env=env,timeout=5)
   assert headless.returncode==1 and '--code-only' in headless.stderr and not headless.stdout
   code=re.search(r'Pairing code:\s+([0-9]{6})',fallback.stdout).group(1)
   request=urllib.request.Request(f'https://127.0.0.1:{port}/admin/pair-qr',method='POST',headers={'Authorization':'Bearer '+(root/'admin-token').read_text().strip()})
   secret=json.loads(urllib.request.urlopen(request,context=context,timeout=5).read())['secret']
   logs=(root/'serve.log').read_text()+(root/'logs/bridge.log').read_text()
   assert code not in logs and secret not in logs
   assert not (root/'Library/Group Containers/group.com.agentcy.iris.prototype/IrisBridge/local-identity.json').exists()
   print('CLI isolated TLS/PTY: wide QR, narrow width guidance, code-only fallback, headless refusal, no credential logs, no app-group write: passed.')
  finally:
   server.terminate()
   try: server.wait(timeout=5)
   except subprocess.TimeoutExpired: server.kill(); server.wait()
