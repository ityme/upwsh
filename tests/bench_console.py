"""Measure empty Enter or Git candidate display through Windows ConPTY."""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
import re
import os
from pathlib import Path
import queue
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time

if sys.platform != 'win32':
    raise SystemExit('ConPTY requires Windows')
k = c.WinDLL('kernel32', use_last_error=True)
class COORD(c.Structure):
    _fields_ = [('X', c.c_short), ('Y', c.c_short)]
class STARTUPINFO(c.Structure):
    _fields_ = [('cb', w.DWORD), ('lpReserved', w.LPWSTR), ('lpDesktop', w.LPWSTR), ('lpTitle', w.LPWSTR), ('dwX', w.DWORD), ('dwY', w.DWORD), ('dwXSize', w.DWORD), ('dwYSize', w.DWORD), ('dwXCountChars', w.DWORD), ('dwYCountChars', w.DWORD), ('dwFillAttribute', w.DWORD), ('dwFlags', w.DWORD), ('wShowWindow', w.WORD), ('cbReserved2', w.WORD), ('lpReserved2', c.POINTER(c.c_byte)), ('hStdInput', w.HANDLE), ('hStdOutput', w.HANDLE), ('hStdError', w.HANDLE)]
class STARTUPINFOEX(c.Structure):
    _fields_ = [('StartupInfo', STARTUPINFO), ('lpAttributeList', c.c_void_p)]
class PROCESSINFO(c.Structure):
    _fields_ = [('hProcess', w.HANDLE), ('hThread', w.HANDLE), ('dwProcessId', w.DWORD), ('dwThreadId', w.DWORD)]
k.CreatePipe.argtypes = [c.POINTER(w.HANDLE), c.POINTER(w.HANDLE), c.c_void_p, w.DWORD]
k.CreatePseudoConsole.argtypes = [COORD, w.HANDLE, w.HANDLE, w.DWORD, c.POINTER(w.HANDLE)]
k.CreatePseudoConsole.restype = c.c_long
k.InitializeProcThreadAttributeList.argtypes = [c.c_void_p, w.DWORD, w.DWORD, c.POINTER(c.c_size_t)]
k.UpdateProcThreadAttribute.argtypes = [c.c_void_p, w.DWORD, c.c_size_t, c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p]
k.CreateProcessW.argtypes = [w.LPCWSTR, w.LPWSTR, c.c_void_p, c.c_void_p, w.BOOL, w.DWORD, c.c_void_p, w.LPCWSTR, c.POINTER(STARTUPINFOEX), c.POINTER(PROCESSINFO)]
k.ReadFile.argtypes = [w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.c_void_p]
k.WriteFile.argtypes = k.ReadFile.argtypes
k.CloseHandle.argtypes = [w.HANDLE]
k.ClosePseudoConsole.argtypes = [w.HANDLE]
k.TerminateProcess.argtypes = [w.HANDLE, w.UINT]
k.DeleteProcThreadAttributeList.argtypes = [c.c_void_p]

def check(ok):
    if not ok:
        raise c.WinError(c.get_last_error())

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('profile', nargs='?', default='src/profile.ps1')
parser.add_argument('--samples', type=int, default=40)
parser.add_argument('--budget-ms', type=float, default=30)
parser.add_argument('--enforce', action='store_true')
parser.add_argument('--completion', action='store_true', help='Measure git pull origin <Tab> in an isolated repository')
parser.add_argument('--quoted-path', action='store_true', help='Verify quoted directory/file completion cursor and continued typing')
parser.add_argument('--lifecycle', action='store_true', help='Verify render counts for redraw, cancellation, submission, and interruption')
parser.add_argument('--osc', action='store_true', help='Verify OSC frame order, encoded cwd and delta reporting on the wire')
options = parser.parse_args()
if sum([options.completion, options.lifecycle, options.osc]) > 1:
    parser.error('choose --completion, --lifecycle or --osc')
if options.samples < 1:
    parser.error('--samples must be positive')
runtime = Path(options.profile).resolve()
bench_home = Path(tempfile.mkdtemp(prefix='upwsh-console-'))
in_read, in_write, out_read, out_write, console = [w.HANDLE() for _ in range(5)]
process = PROCESSINFO()
attributes = None
chunks = queue.Queue()

def send(data):
    written = w.DWORD()
    check(k.WriteFile(in_write, data, len(data), c.byref(written), None))

def read_loop():
    buffer = c.create_string_buffer(65536)
    size = w.DWORD()
    while k.ReadFile(out_read, buffer, len(buffer), c.byref(size), None) and size.value:
        chunks.put(buffer.raw[:size.value])

def capture_buffer(keys, timeout=15):
    start = time.perf_counter()
    send(keys + bytes([7]))  # Ctrl+g captures state after the preceding key handler finishes.
    data = b''
    while time.perf_counter() - start < timeout:
        part = chunks.get(timeout=max(0.01, timeout - (time.perf_counter() - start)))
        data += part
        if b'\x1b[6n' in part:
            send(b'\x1b[1;1R')
        if b'UPWSH_CAPTURE_READY' in data:
            result = json.loads((bench_home / 'capture.json').read_text(encoding='utf-8'))
            result['ms'] = (time.perf_counter() - start) * 1000
            result['prompt_events'] = data.count(b'\x1b]133;A')
            result['finished_events'] = data.count(b'\x1b]133;D;')
            result['candidates_visible'] = b'dev' in data and b'main' in data
            if options.osc:
                result['wire'] = data
            return result
    raise RuntimeError('Timed out capturing PSReadLine state')


def await_prompt(timeout=15):
    data = b''
    deadline = time.perf_counter() + timeout
    while time.perf_counter() < deadline:
        try:
            part = chunks.get(timeout=max(0.01, deadline - time.perf_counter()))
        except queue.Empty:
            break
        data += part
        if b'\x1b[6n' in part:
            send(b'\x1b[1;1R')
        if b'\x1b]133;B\x07' in data:
            return data
    raise RuntimeError('Timed out waiting for prompt; terminal output withheld')

try:
    check(k.CreatePipe(c.byref(in_read), c.byref(in_write), None, 0))
    check(k.CreatePipe(c.byref(out_read), c.byref(out_write), None, 0))
    hr = k.CreatePseudoConsole(COORD(120, 30), in_read, out_write, 0, c.byref(console))
    if hr != 0:
        raise RuntimeError(f'CreatePseudoConsole HRESULT={hr}')
    k.CloseHandle(in_read); in_read = w.HANDLE()
    k.CloseHandle(out_write); out_write = w.HANDLE()
    size = c.c_size_t()
    k.InitializeProcThreadAttributeList(None, 1, 0, c.byref(size))
    attributes = c.create_string_buffer(size.value)
    check(k.InitializeProcThreadAttributeList(attributes, 1, 0, c.byref(size)))
    check(k.UpdateProcThreadAttribute(attributes, 0, 0x20016, console, c.sizeof(w.HANDLE), None, None))
    startup = STARTUPINFOEX()
    startup.StartupInfo.cb = c.sizeof(startup)
    startup.StartupInfo.dwFlags = 0x00000100
    startup.lpAttributeList = c.cast(attributes, c.c_void_p)
    env = dict(os.environ)
    config = Path(env.get('STARSHIP_CONFIG', str(Path.home() / '.config/starship.toml')))
    if config.exists():
        env['STARSHIP_CONFIG'] = str(config)
    env['USERPROFILE'] = str(bench_home)
    env['LOCALAPPDATA'] = str(bench_home / 'AppData/Local')
    env['APPDATA'] = str(bench_home / 'AppData/Roaming')
    env['UPWSH_SKIP_PERSIST_PATH'] = '1'
    env['UPWSH_PROFILE'] = str(bench_home / 'profile.ps1')
    for key in ['UPWSH_OSC', 'UPWSH_OSC_FIELDS', 'UPWSH_OSC_COMMAND']:
        env.pop(key, None)
    if options.osc:
        env['UPWSH_OSC'] = 'On'
        env['UPWSH_BENCH_CWD'] = str(bench_home / 'space # literal%20')
        Path(env['UPWSH_BENCH_CWD']).mkdir()
        (Path(env['UPWSH_BENCH_CWD']) / 'foreground').mkdir()
    working_directory = os.getcwd()
    if options.quoted_path:
        fixture = bench_home / 'quoted-fixture'
        (fixture / 'space folder').mkdir(parents=True)
        (fixture / 'space folder' / 'child file.txt').write_text('fixture', encoding='utf-8')
        (fixture / 'shared alpha').mkdir()
        (fixture / 'shared beta').mkdir()
        working_directory = str(fixture)
    if options.completion:
        fixture = bench_home / 'repo'
        fixture.mkdir()
        working_directory = str(fixture)
        for key in list(env):
            if key.upper().startswith('GIT_'):
                del env[key]
        env['GIT_CONFIG_GLOBAL'] = os.devnull
        env['GIT_CONFIG_NOSYSTEM'] = '1'
        for args in [
            ['init', '--initial-branch=main'],
            ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'fixture'],
            ['remote', 'add', 'origin', 'https://example.invalid/repo.git'],
            ['update-ref', 'refs/remotes/origin/dev', 'HEAD'],
            ['update-ref', 'refs/remotes/origin/main', 'HEAD'],
        ]:
            subprocess.run(['git', '-C', str(fixture), *args], env=env, check=True, capture_output=True)
    env_block = c.create_unicode_buffer('\0'.join(f'{key}={value}' for key, value in sorted(env.items())) + '\0\0')
    script = ". '" + str(runtime).replace("'", "''") + "'"
    if options.completion or options.lifecycle or options.osc or options.quoted_path:
        script += r""";
Set-PSReadLineOption -HistorySavePath (Join-Path $HOME 'fixture-history.txt') -HistorySaveStyle SaveNothing
$global:UpwshBenchRenders = 0
$module = (Get-Command prompt).Module
$global:UpwshBenchBase = & $module { $script:BasePrompt }
& $module { $script:BasePrompt = { $global:UpwshBenchSucceeded = $global:?; $global:UpwshBenchRenders++; & $global:UpwshBenchBase } }
Set-PSReadLineKeyHandler -Chord Ctrl+o -Function AcceptAndGetNext
Set-PSReadLineKeyHandler -Chord Ctrl+g -ScriptBlock {
    $line = $null; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    $module = (Get-Command prompt).Module
    $status = & $module { [pscustomobject]@{ Pending = $script:CommandPending; Succeeded = $script:LastCommandSucceeded; Exit = $script:LastCommandExitCode } }
    $state = [pscustomobject]@{ Line = $line; Cursor = $cursor; Renders = $global:UpwshBenchRenders; RendererSucceeded = $global:UpwshBenchSucceeded; Status = $status }
    [IO.File]::WriteAllText((Join-Path $HOME 'capture.json'), ($state | ConvertTo-Json -Compress))
    [Console]::Write('UPWSH_CAPTURE_READY')
}
"""
    if options.osc:
        script += r""";
& (Get-Command prompt).Module {
    $script:CachedPrompt = $null
    $script:BasePrompt = { $global:UpwshBenchRenders++; 'UPWSH_VISIBLE_PROMPT> ' }
}
"""
    command = c.create_unicode_buffer(subprocess.list2cmdline([shutil.which('pwsh'), '-NoLogo', '-NoProfile', '-NoExit', '-Command', script]))
    start = time.perf_counter()
    check(k.CreateProcessW(None, command, None, None, False, 0x00080000 | 0x00000400, env_block, working_directory, c.byref(startup), c.byref(process)))
    threading.Thread(target=read_loop, daemon=True).start()
    initial_wire = await_prompt()
    startup_ms = (time.perf_counter() - start) * 1000
    if options.osc:
        def verify_frame(wire):
            start_mark = wire.find(b'\x1b]133;A\x07')
            prompt_text = wire.find(b'UPWSH_VISIBLE_PROMPT> ')
            end_mark = wire.find(b'\x1b]133;B\x07')
            assert 0 <= start_mark < prompt_text < end_mark, 'prompt is outside A/B'
        verify_frame(initial_wire)
        previous = capture_buffer(b'')
        clear = capture_buffer(bytes([12]))
        assert clear['Renders'] == previous['Renders'] and clear['prompt_events'] == 0
        idle = capture_buffer(bytes([13]))
        verify_frame(idle['wire'])
        assert b'SetUserVar=' not in idle['wire'] and idle['finished_events'] == 0
        cwd = capture_buffer(b'cd $env:UPWSH_BENCH_CWD\r')
        verify_frame(cwd['wire'])
        assert b'\x1b]133;C\x07' in cwd['wire'] and b'\x1b]133;D;0\x07' in cwd['wire']
        uris = re.findall(rb'\x1b\]7;([^\x07]+)\x07', cwd['wire'])
        assert uris and b'space%20%23%20literal%2520' in uris[-1], 'incorrect encoded cwd'
        from urllib.parse import urlsplit, unquote
        parsed = urlsplit(uris[-1].decode('utf-8'))
        assert not parsed.fragment and unquote(parsed.path).lstrip('/') == env['UPWSH_BENCH_CWD'].replace('\\', '/')
        # Hold a native foreground process open: CWD must be sent before it starts,
        # without relying on the PowerShell prompt after the process exits.
        send(b"""cd (Join-Path $env:UPWSH_BENCH_CWD 'foreground'); & (Get-Process -Id $PID).Path -NoLogo -NoProfile -Command "[Console]::Write('UPWSH_FOREGROUND_READY'); [void][Console]::ReadLine()"\r""")
        wire = b''
        deadline = time.perf_counter() + 20
        while time.perf_counter() < deadline:
            try:
                part = chunks.get(timeout=max(.01, deadline - time.perf_counter()))
            except queue.Empty:
                break
            wire += part
            if b'\x1b[6n' in part:
                send(b'\x1b[1;1R')
            # The token also appears in the echoed command, so check after OSC133 C.
            running = wire.find(b'\x1b]133;C\x07')
            if running >= 0 and b'UPWSH_FOREGROUND_READY' in wire[running:]:
                break
        running = wire.find(b'\x1b]133;C\x07')
        active = wire[running:] if running >= 0 else b''
        marker = active.find(b'UPWSH_FOREGROUND_READY')
        cwd_event = active.find(b'\x1b]7;')
        assert 0 <= cwd_event < marker, 'CWD was not sent before the foreground process'
        assert b'/foreground\x07' in active[:marker], 'foreground CWD missing'
        assert b'\x1b]133;A' not in active and b'\x1b]133;D;' not in active, 'cd invented prompt/completion events'
        send(b'\r')
        await_prompt()
        failure = capture_buffer(b'Write-Error "OSC fixture"\r')
        verify_frame(failure['wire'])
        assert b'\x1b]133;D;1\x07' in failure['wire']
        after = capture_buffer(bytes([13]))
        assert after['finished_events'] == 0 and b'LAST_ELAPSED_MS=' not in after['wire']
        assert after['Status']['Succeeded'] is False
        print(json.dumps({'wire_order': 'A < visible prompt < B', 'cwd_encoding': True,
                          'idle_fields_omitted': True, 'cwd_before_foreground': True, 'failure_exit': 1, 'passed': True}))
    elif options.lifecycle:
        rows = []
        previous = capture_buffer(b'')

        def check_action(name, keys, renders, expected_line='', finishes=0, interrupt=False):
            global previous
            if interrupt:
                # Console cancellation may flush queued keys. Wait for the new prompt before Ctrl+g.
                begin = time.perf_counter()
                send(keys)
                events = await_prompt()
                result = capture_buffer(b'')
                result['ms'] = (time.perf_counter() - begin) * 1000
                result['finished_events'] += events.count(b'\x1b]133;D;')
                result['prompt_events'] += events.count(b'\x1b]133;A')
            else:
                result = capture_buffer(keys)
            delta = result['Renders'] - previous['Renders']
            row = {'action': name, 'ms': round(result['ms'], 2), 'renders': delta,
                   'finished_events': result['finished_events'], 'prompt_events': result['prompt_events'],
                   'line': result['Line'], 'status': result['Status'], 'renderer_succeeded': result['RendererSucceeded']}
            rows.append(row)
            assert delta == renders, row
            assert result['Line'] == expected_line, row
            assert result['finished_events'] == finishes, row
            previous = result
            return result

        check_action('type without execution', b'$null=1', 0, '$null=1')
        check_action('Ctrl+L editing', bytes([12]), 0, '$null=1')
        check_action('Ctrl+C cancel editing', bytes([3]), 0)
        check_action('empty Enter', bytes([13]), 0)
        check_action('comment-only Enter', b'# fixture comment\r', 0)
        check_action('block-comment Enter', b'<# fixture comment #>\r', 0)
        check_action('actual assignment', b'$null=1\r', 1, finishes=1)
        check_action('incomplete multiline', b'if ($true) {\r', 0, 'if ($true) {\n')
        check_action('Ctrl+C cancel multiline', bytes([3]), 0)
        check_action('native failure', b'& (Get-Process -Id $PID).Path -NoProfile -Command "exit 7"\r', 1, finishes=1)
        assert previous['Status']['Succeeded'] is False and previous['Status']['Exit'] == 7, rows[-1]
        assert previous['RendererSucceeded'] is False, rows[-1]
        check_action('idle after failure', bytes([13]), 0)
        assert previous['Status']['Succeeded'] is False and previous['Status']['Exit'] == 7, rows[-1]
        check_action('Ctrl+L after failure', bytes([12]), 0)
        # Wait for the command's side effect, not an arbitrary sleep, before interrupting it.
        send(b'[IO.File]::WriteAllText((Join-Path $HOME "running.flag"), "ready"); Start-Sleep 30\r')
        deadline = time.perf_counter() + 15
        while not (bench_home / 'running.flag').exists():
            if time.perf_counter() >= deadline:
                raise RuntimeError('interruption fixture did not begin execution')
            time.sleep(0.02)
        check_action('Ctrl+C interrupt execution', bytes([3]), 1, finishes=1, interrupt=True)
        assert previous['Status']['Pending'] is False and previous['Status']['Succeeded'] is False, rows[-1]
        assert previous['RendererSucceeded'] is False, rows[-1]
        check_action('redraw after interruption', bytes([12]), 0)
        check_action('success after interruption', b'$null=2\r', 1, finishes=1)
        assert previous['Status']['Succeeded'] is True and previous['RendererSucceeded'] is True, rows[-1]
        check_action('Ctrl+o alternative submit', b'$null=3' + bytes([15]), 1, finishes=1)
        check_action('path-shaped text stays unchanged on Enter', b'Write-Output /c/fixture\r', 1, finishes=1)
        check_action('recall original Unix command', b'\x1b[A', 0, 'Write-Output /c/fixture')
        check_action('cancel recalled input', bytes([3]), 0)
        check_action('cmdlet failure', b'Write-Error "fixture failure"\r', 1, finishes=1)
        assert previous['Status']['Succeeded'] is False and previous['RendererSucceeded'] is False, rows[-1]
        check_action('submitted syntax error', b'1 + * 2\r', 1, finishes=1)
        assert previous['Status']['Succeeded'] is False, rows[-1]
        check_action('idle after syntax error', bytes([13]), 0)
        check_action('empty Ctrl+C', bytes([3]), 0)
        print(json.dumps({'lifecycle_checks': rows, 'passed': True}))
    elif options.quoted_path:
        rows = []
        for command in ('touch -p', 'cp', 'mv', 'ls', 'git add', 'git checkout'):
            row = capture_buffer(command.encode() + b' spa\t')
            expected = command + " 'space folder/'"
            assert row['Line'] == expected and row['Cursor'] == len(expected) - 1, row
            assert 'winpath' not in row['Line'], row
            rows.append({'command': command, 'directory': True})
            send(bytes([3]))
            await_prompt()
        row = capture_buffer(b'touch -p sha\t')
        expected = "touch -p 'shared '"
        assert row['Line'] == expected and row['Cursor'] == len(expected) - 1, row
        send(bytes([3]))
        await_prompt()
        row = capture_buffer(b'touch -p spa\tchi\t')
        expected = "touch -p 'space folder/child file.txt'"
        assert row['Line'] == expected and row['Cursor'] == len(expected) - 1, row
        row = capture_buffer(b'.bak')
        assert row['Line'] == "touch -p 'space folder/child file.txt.bak'", row
        assert row['Cursor'] == len(row['Line']) - 1, row
        print(json.dumps({'quoted_path_checks': rows, 'continued_typing': True, 'passed': True}))
    elif options.completion:
        typed = capture_buffer(b'git pull origin ')
        rows = [capture_buffer(bytes([9])) for _ in range(options.samples + 5)]
        input_preserved = all(row['Line'] == 'git pull origin ' and row['Cursor'] == 16 for row in rows)
        redraw_reused = all(row['Renders'] == typed['Renders'] and row['prompt_events'] == 0 for row in rows)
        candidates_visible = any(row['candidates_visible'] for row in rows)
        correct = input_preserved and redraw_reused and candidates_visible
        samples = sorted(row['ms'] for row in rows[5:])
        p95 = samples[min(len(samples) - 1, int(len(samples) * .95))]
        print(json.dumps({'samples': len(samples), 'first_display_ms': round(rows[0]['ms'], 2),
                          'display_median_ms': round(statistics.median(samples), 2),
                          'display_p95_ms': round(p95, 2),
                          'extra_prompt_renders': rows[-1]['Renders'] - typed['Renders'],
                          'extra_prompt_events': sum(row['prompt_events'] for row in rows),
                          'input_preserved': input_preserved, 'candidates_visible': candidates_visible,
                          'executed_pull': False,
                          'budget_ms': options.budget_ms, 'passed': correct and p95 < options.budget_ms}))
        if not correct or (options.enforce and p95 >= options.budget_ms):
            sys.exit(1)
    else:
        times = []
        for _ in range(options.samples + 5):
            time.sleep(0.04)
            while not chunks.empty(): chunks.get_nowait()
            start = time.perf_counter()
            send(b'\r')
            await_prompt()
            times.append((time.perf_counter() - start) * 1000)
        samples = sorted(times[5:])
        p95 = samples[min(len(samples) - 1, int(len(samples) * .95))]
        print(json.dumps({'samples': len(samples), 'startup_to_prompt_ms': round(startup_ms, 2), 'empty_enter_median_ms': round(statistics.median(samples), 2), 'empty_enter_p95_ms': round(p95, 2), 'max_ms': round(max(samples), 2), 'budget_ms': options.budget_ms, 'passed': p95 < options.budget_ms}))
        if options.enforce and p95 >= options.budget_ms:
            sys.exit(1)
finally:
    if process.hProcess: k.TerminateProcess(process.hProcess, 0)
    if console: k.ClosePseudoConsole(console)
    if attributes: k.DeleteProcThreadAttributeList(attributes)
    for handle in [process.hThread, process.hProcess, in_read, in_write, out_read, out_write]:
        if handle: k.CloseHandle(handle)
    shutil.rmtree(bench_home, ignore_errors=True)
