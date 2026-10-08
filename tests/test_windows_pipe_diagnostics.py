from __future__ import annotations
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('pipe_probe', ROOT / 'scripts/windows-pipe-diagnostics.py')
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)

class WindowsPipeDiagnosticsTest(unittest.TestCase):
    def setUp(self):
        probe._UNREAPED_WORKERS.clear()

    def tearDown(self):
        probe._UNREAPED_WORKERS.clear()

    def process(self, output=b''):
        process=Mock();process.returncode=0;process.communicate.return_value=(output,b'')
        return process

    def test_spawn_failure_is_reported_without_claiming_started(self):
        with patch.object(probe.subprocess,'Popen',side_effect=OSError(5,'synthetic')):
            report=probe.supervise('sync-duplex')
        self.assertFalse(report['started'])
        self.assertEqual(report['status'],'spawn-failed')
        self.assertEqual(report['api_error'],5)

    def test_failed_cleanup_prevents_starting_later_scenarios(self):
        def unresolved(scenario):
            probe._UNREAPED_WORKERS.append(object())
            return {'scenario':scenario,'started':True,'status':'timeout'}
        with patch.object(probe,'supervise',side_effect=unresolved) as supervise:
            reports=probe.collect_scenarios()
        self.assertEqual(supervise.call_count,1)
        self.assertEqual(len(reports),len(probe.SCENARIOS))
        self.assertTrue(all(r['status']=='not-run' for r in reports[1:]))

    def test_fixed_scenarios_only(self):
        with self.assertRaises(ValueError):probe.supervise('arbitrary-command')

    def test_completed_means_collection_not_product_pass(self):
        process=self.process(b'{"phase":"finished"}\n')
        with patch.object(probe.subprocess,'Popen',return_value=process) as spawn:
            report=probe.supervise('sync-duplex')
        self.assertEqual(report['status'],'completed')
        self.assertTrue(report['started']);self.assertTrue(report['cleanup_completed'])
        self.assertFalse(report['cancellation_observed'])
        self.assertEqual(spawn.call_args.args[0][-2:],['--worker','sync-duplex'])
        self.assertNotIn('shell',spawn.call_args.kwargs)
        process.kill.assert_not_called()

    def test_watchdog_kills_only_its_worker_and_bounds_reap(self):
        process=self.process();process.returncode=-9
        process.communicate.side_effect=[subprocess.TimeoutExpired('probe',8),(b'',b'')]
        with patch.object(probe.subprocess,'Popen',return_value=process):report=probe.supervise('sync-duplex')
        process.kill.assert_called_once_with()
        self.assertTrue(report['watchdog_expired']);self.assertEqual(report['status'],'timeout')
        self.assertEqual(process.communicate.call_args_list[-1].kwargs,{'timeout':2})

    def test_failed_reap_is_reported_not_waited_forever(self):
        process=self.process();process.communicate.side_effect=subprocess.TimeoutExpired('probe',8)
        with patch.object(probe.subprocess,'Popen',return_value=process):report=probe.supervise('sync-write-cancel')
        self.assertEqual(report['cleanup_error'],'TimeoutExpired')
        self.assertEqual(process.communicate.call_count,2)
        process.stdout.close.assert_not_called()
        self.assertIn(process,probe._UNREAPED_WORKERS)

    def test_failed_kill_is_reported(self):
        process=self.process();process.communicate.side_effect=subprocess.TimeoutExpired('probe',8)
        process.kill.side_effect=OSError('synthetic')
        with patch.object(probe.subprocess,'Popen',return_value=process):report=probe.supervise('sync-duplex')
        self.assertEqual(report['cleanup_error'],'OSError')
        self.assertEqual(process.communicate.call_count,1)

    def test_cancellation_requires_completion_error(self):
        output=b'{"phase":"cancel-write","ok":true}\n'
        process=self.process(output)
        with patch.object(probe.subprocess,'Popen',return_value=process):report=probe.supervise('overlapped-write-cancel')
        self.assertFalse(report['cancellation_observed'])
        process.communicate.return_value=(output+b'{"phase":"write-large-complete","error":995}\n',b'')
        with patch.object(probe.subprocess,'Popen',return_value=process):report=probe.supervise('overlapped-write-cancel')
        self.assertTrue(report['cancellation_observed'])

    def test_stderr_is_not_disclosed_and_parse_is_bounded(self):
        process=self.process(b'not-json\n'+b'x'*40000)
        process.communicate.return_value=(b'x'*40000,b'synthetic-private-path')
        with patch.object(probe.subprocess,'Popen',return_value=process):report=probe.supervise('sync-duplex')
        self.assertTrue(report['output_truncated']);self.assertTrue(report['stderr_present'])
        self.assertNotIn('synthetic-private-path',json.dumps(report))

    @unittest.skipIf(probe.os.name=='nt','non-Windows branch only')
    def test_nonwindows_is_not_run(self):
        with tempfile.TemporaryDirectory() as directory:
            destination=Path(directory)/'report.json'
            with patch('sys.stdout',new=io.StringIO()):self.assertEqual(probe.main(['--output',str(destination)]),0)
            self.assertEqual(json.loads(destination.read_text())['status'],'not-run')

    def test_workflow_uses_existing_job_and_preserves_product_command(self):
        source=(ROOT/'.github/workflows/local-ci-gate.yml').read_text()
        windows=source.split('  windows-native:',1)[1].split('  macos-native:',1)[0]
        self.assertIn('python scripts/windows-pipe-diagnostics.py --output build/evidence/windows-pipe-diagnostics.json',windows)
        self.assertIn('scripts/vityo.py deliver --mode ci --platform windows',windows)
        self.assertIn('timeout-minutes: 75',windows)
        self.assertNotIn('continue-on-error: true',windows)
        self.assertIn('vityo-nightly/build/evidence/windows-pipe-diagnostics.json',windows)

if __name__=='__main__':unittest.main()
