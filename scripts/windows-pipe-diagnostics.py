"""Bounded Win32 named-pipe diagnostics; no product or user-state mutation."""
from __future__ import annotations
import argparse
import ctypes
import json
import os
import platform
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid

# Keep native buffers rooted even if worker() raises before immediate process exit.
_LIVE_IO = []
_UNREAPED_WORKERS = []

SCENARIOS = ('sync-duplex', 'overlapped-duplex', 'sync-write-cancel', 'overlapped-write-cancel', 'sync-write-close')

def supervise(scenario: str, timeout: float = 8.0) -> dict:
    if scenario not in SCENARIOS:
        raise ValueError('unknown scenario')
    command = [sys.executable, str(Path(__file__).resolve()), '--worker', scenario]
    started = time.monotonic()
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as error:
        return {'scenario': scenario, 'started': False, 'status': 'spawn-failed',
                'api_error': error.errno, 'events': []}
    timed_out = False
    cleanup_error = None
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        # The worker starts native threads only, never child processes.
        try:
            process.kill()
            stdout, stderr = process.communicate(timeout=2)
        except (OSError, subprocess.TimeoutExpired) as error:
            cleanup_error = type(error).__name__
            stdout, stderr = b'', b''
            # Never block the supervisor to reap an uncooperative worker.
            # Windows communicate reader threads may hold stream locks. Never
            # synchronously close their streams here; retain them until the
            # reporting parent terminates without interpreter finalization.
            _UNREAPED_WORKERS.append(process)
    events = []
    for line in stdout[:32768].decode('utf-8', errors='replace').splitlines():
        try:
            item = json.loads(line)
            if isinstance(item, dict):
                events.append(item)
        except ValueError:
            pass
    return {'scenario': scenario, 'started': True,
            'status': 'timeout' if timed_out else ('completed' if process.returncode == 0 else 'failed'),
            'returncode': process.returncode,
            'watchdog_expired': timed_out, 'cleanup_error': cleanup_error, 'elapsed_seconds': round(time.monotonic()-started, 3),
            'cancellation_observed': any(e.get('error') == 995 and ('return' in e.get('phase','') or 'complete' in e.get('phase','')) for e in events),
            'cleanup_completed': any(e.get('phase') == 'finished' for e in events),
            'events': events, 'stderr_present': bool(stderr),
            'output_truncated': len(stdout) > 32768 or len(stderr) > 32768}

def worker(scenario: str) -> int:
    from ctypes import wintypes as w
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    HANDLE = w.HANDLE
    class OVERLAPPED(ctypes.Structure):
        _fields_ = [('Internal', ctypes.c_size_t), ('InternalHigh', ctypes.c_size_t),
                    ('Offset', w.DWORD), ('OffsetHigh', w.DWORD), ('hEvent', HANDLE)]
    def bind(name, result, args):
        fn=getattr(kernel,name);fn.restype=result;fn.argtypes=args;return fn
    create_pipe=bind('CreateNamedPipeW',HANDLE,[w.LPCWSTR,w.DWORD,w.DWORD,w.DWORD,w.DWORD,w.DWORD,w.DWORD,ctypes.c_void_p])
    connect_pipe=bind('ConnectNamedPipe',w.BOOL,[HANDLE,ctypes.c_void_p])
    create_file=bind('CreateFileW',HANDLE,[w.LPCWSTR,w.DWORD,w.DWORD,ctypes.c_void_p,w.DWORD,w.DWORD,HANDLE])
    read=bind('ReadFile',w.BOOL,[HANDLE,ctypes.c_void_p,w.DWORD,ctypes.POINTER(w.DWORD),ctypes.c_void_p])
    write=bind('WriteFile',w.BOOL,[HANDLE,ctypes.c_void_p,w.DWORD,ctypes.POINTER(w.DWORD),ctypes.c_void_p])
    close=bind('CloseHandle',w.BOOL,[HANDLE])
    cancel=bind('CancelIoEx',w.BOOL,[HANDLE,ctypes.c_void_p])
    event=bind('CreateEventW',HANDLE,[ctypes.c_void_p,w.BOOL,w.BOOL,w.LPCWSTR])
    wait=bind('WaitForSingleObject',w.DWORD,[HANDLE,w.DWORD])
    result=bind('GetOverlappedResult',w.BOOL,[HANDLE,ctypes.POINTER(OVERLAPPED),ctypes.POINTER(w.DWORD),w.BOOL])
    start=time.monotonic()
    def emit(phase, **data):
        print(json.dumps({'phase':phase,'milliseconds':round((time.monotonic()-start)*1000),**data}),flush=True)
    def checked(handle):
        if handle in (None, ctypes.c_void_p(-1).value):
            raise OSError(ctypes.get_last_error())
        return handle
    name=r'\\.\pipe\vityo-probe-'+uuid.uuid4().hex
    server=checked(create_pipe(name,3,0,1,4096,4096,0,None))
    connected=threading.Event(); server_finished=threading.Event(); hold=threading.Event()
    def serve():
        try:
            ok=connect_pipe(server,None);error=ctypes.get_last_error() if not ok else 0
            emit('server-connect',ok=bool(ok) or error==535,error=error)
            if not ok and error!=535:return
            connected.set()
            if 'write-' in scenario:
                hold.wait(6);return
            buffer=ctypes.create_string_buffer(1);count=w.DWORD()
            emit('server-read-enter')
            ok=read(server,buffer,1,ctypes.byref(count),None)
            emit('server-read-return',ok=bool(ok),bytes=count.value,error=ctypes.get_last_error() if not ok else 0)
            if ok and count.value==1:
                ok=write(server,buffer,1,ctypes.byref(count),None)
                emit('server-write-return',ok=bool(ok),bytes=count.value,error=ctypes.get_last_error() if not ok else 0)
        finally:
            server_finished.set()
    threading.Thread(target=serve,daemon=True).start()
    overlapped=scenario.startswith('overlapped')
    client=checked(create_file(name,0xC0000000,0,None,3,0x40000000 if overlapped else 0,None))
    if not connected.wait(1):raise RuntimeError('server connection did not complete')
    emit('client-open',overlapped=overlapped)
    allocations=_LIVE_IO
    def submit(fn,buffer,label):
        op=OVERLAPPED();op.hEvent=checked(event(None,True,False,None));count=w.DWORD()
        allocations.append((op,buffer,count)) # Keep all buffers alive until completion.
        ok=fn(client,buffer,len(buffer.raw) if label=='write-large' else 1,None,ctypes.byref(op))
        error=ctypes.get_last_error() if not ok else 0
        emit(label+'-submit',ok=bool(ok),error=error)
        return op, bool(ok), error
    def finish(op,label,timeout=1500):
        status=wait(op.hEvent,timeout)
        if status!=0:
            emit(label+'-wait',wait_status=status);return False
        count=w.DWORD();ok=result(client,ctypes.byref(op),ctypes.byref(count),False)
        error=ctypes.get_last_error() if not ok else 0
        emit(label+'-complete',ok=bool(ok),error=error,bytes=count.value)
        return bool(ok) or error==995
    if scenario=='sync-duplex':
        finished_read=threading.Event();finished_write=threading.Event();entered=threading.Event()
        def reader():
            buffer=ctypes.create_string_buffer(1);count=w.DWORD();emit('client-read-enter');entered.set()
            ok=read(client,buffer,1,ctypes.byref(count),None);emit('client-read-return',ok=bool(ok),error=ctypes.get_last_error() if not ok else 0);finished_read.set()
        def writer():
            buffer=ctypes.create_string_buffer(b'x',1);count=w.DWORD();emit('client-write-enter')
            ok=write(client,buffer,1,ctypes.byref(count),None);emit('client-write-return',ok=bool(ok),error=ctypes.get_last_error() if not ok else 0);finished_write.set()
        threading.Thread(target=reader,daemon=True).start();entered.wait(1);time.sleep(.1)
        emit('reader-pending-before-write',pending=not finished_read.is_set())
        threading.Thread(target=writer,daemon=True).start();time.sleep(.5)
        emit('duplex-observation',read_done=finished_read.is_set(),write_done=finished_write.is_set())
        ok=cancel(client,None);emit('cancel-all',ok=bool(ok),error=ctypes.get_last_error() if not ok else 0)
        if not finished_read.wait(1) or not finished_write.wait(1):
            emit('completion-unresolved');os._exit(2) # Never unwind buffers while native I/O may still use them.
    elif scenario=='overlapped-duplex':
        r,ok,error=submit(read,ctypes.create_string_buffer(1),'read')
        if not ok and error!=997:os._exit(3)
        op,ok,error=submit(write,ctypes.create_string_buffer(b'x',1),'write')
        if not ok and error!=997:os._exit(3)
        if not finish(op,'write') or not finish(r,'read'):os._exit(2)
    else:
        payload=ctypes.create_string_buffer(b'x'*(1024*1024),1024*1024)
        if overlapped:
            op,ok,error=submit(write,payload,'write-large')
            if ok or error!=997:
                emit('pending-write-not-established');os._exit(3)
            time.sleep(.1)
            if wait(op.hEvent,0)==0:
                emit('write-completed-before-cancel');os._exit(3)
            ok=cancel(client,ctypes.byref(op));emit('cancel-write',ok=bool(ok),error=ctypes.get_last_error() if not ok else 0)
            if not finish(op,'write-large'):os._exit(2)
        else:
            done=threading.Event();entered=threading.Event()
            def writer():
                count=w.DWORD();emit('write-large-enter');entered.set()
                ok=write(client,payload,len(payload.raw),ctypes.byref(count),None)
                emit('write-large-return',ok=bool(ok),error=ctypes.get_last_error() if not ok else 0,bytes=count.value);done.set()
            threading.Thread(target=writer,daemon=True).start();entered.wait(1);time.sleep(.2)
            emit('wait-before-cancel',write_done=done.is_set())
            if done.is_set():os._exit(3)
            if scenario == 'sync-write-close':
                emit('close-with-pending-write-enter')
                ok=close(client)
                emit('close-with-pending-write-return',ok=bool(ok),error=ctypes.get_last_error() if not ok else 0)
                if not ok:os._exit(4)
                if not done.wait(1.5):emit('completion-unresolved');os._exit(2)
                hold.set()
                if not server_finished.wait(1):emit('server-unresolved');os._exit(2)
                close(server);emit('finished');return 0
            ok=cancel(client,None);emit('cancel-write',ok=bool(ok),error=ctypes.get_last_error() if not ok else 0)
            if not done.wait(1.5):emit('completion-unresolved');os._exit(2)
    # Completion acknowledged before handle/event teardown.
    emit('close-enter');ok=close(client);emit('close-return',ok=bool(ok),error=ctypes.get_last_error() if not ok else 0)
    if not ok:os._exit(4)
    hold.set()
    if not server_finished.wait(1):emit('server-unresolved');os._exit(2)
    close(server)
    for op,_,_ in allocations:close(op.hEvent)
    emit('finished');return 0

def collect_scenarios():
    reports = []
    for scenario in SCENARIOS:
        if _UNREAPED_WORKERS:
            reports.append({'scenario': scenario, 'started': False,
                            'status': 'not-run', 'reason': 'prior-cleanup-incomplete'})
        else:
            reports.append(supervise(scenario))
    return reports

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker',choices=SCENARIOS)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args(argv)
    if os.name!='nt':
        report={'schema_version':1,'platform':'non-windows','status':'not-run','reason':'requires-win32'}
    elif args.worker:
        try:return worker(args.worker)
        except BaseException as error:
            print(json.dumps({'phase':'worker-error','type':type(error).__name__, 'api_error':error.args[0] if error.args and isinstance(error.args[0],int) else None}),flush=True);os._exit(4)
    else:
        report={'schema_version':1,'platform':'windows','os_version':platform.version(),'architecture':platform.machine(),'status':'diagnostic-only','product_validation':False,'completion_meaning':'diagnostic execution only; inspect API outcomes, not a product pass','scenarios':collect_scenarios()}
    report['cleanup_incomplete'] = bool(_UNREAPED_WORKERS)
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2), flush=True)
    return 1 if _UNREAPED_WORKERS else 0
if __name__=='__main__':
    exit_code = 1
    try:
        exit_code = main()
    finally:
        # This also covers report-write failures and interruption after failed
        # cleanup: never run stream finalizers while reader threads own locks.
        if _UNREAPED_WORKERS:
            os._exit(exit_code)
    raise SystemExit(exit_code)
