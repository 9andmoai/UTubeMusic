import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Python'))
import music_catalog


class LoudnessAndCleanupTests(unittest.TestCase):
    def test_optional_source_reference_and_audio_format_fallback(self):
        self.assertEqual(music_catalog.loudness_value({'playerConfig': {'audioConfig': {'loudnessDb': 6}}}), 6)
        self.assertEqual(music_catalog.loudness_value({'streamingData': {'adaptiveFormats': [{'mimeType': 'audio/mp4', 'loudnessDb': -2}]}}), -2)

    def test_invalid_source_metadata_is_not_used(self):
        for value in [None, True, float('nan'), float('inf'), 'bad', 200]:
            self.assertIsNone(music_catalog.loudness_value({'playerConfig': {'audioConfig': {'loudnessDb': value}}}))
        for data in [{}, None, {'playerConfig': None}]:
            self.assertIsNone(music_catalog.loudness_value(data))

    def test_audio_timing_uses_only_the_matching_aac_format(self):
        data = {'streamingData': {'adaptiveFormats': [
            {'itag': 251, 'mimeType': 'audio/webm', 'approxDurationMs': '400000'},
            {'itag': 140, 'mimeType': 'audio/mp4', 'approxDurationMs': '391052'}]}}
        self.assertEqual(music_catalog.audio_duration(data, '140-drc'), 391.052)
        self.assertIsNone(music_catalog.audio_duration(data, '141'))
        self.assertIsNone(music_catalog.audio_duration(data, None))

    def test_invalid_audio_timing_never_becomes_an_end_boundary(self):
        for value in [None, True, 'nan', 'inf', '-1', '0', '9999999999']:
            data = {'streamingData': {'adaptiveFormats': [{'itag':140, 'mimeType':'audio/mp4', 'approxDurationMs':value}]}}
            self.assertIsNone(music_catalog.audio_duration(data, '140'))

    def test_cleanup_only_removes_cpython_regression_suite(self):
        spec = importlib.util.spec_from_file_location('embed', ROOT / 'scripts/embed_python.py')
        embed = importlib.util.module_from_spec(spec); spec.loader.exec_module(embed)
        (ROOT / 'build').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
            app = Path(temp)
            paths = ['python/lib/python3.13/test/support/data', 'python/lib/python3.13/unittest/__init__.py',
                     'python/lib/python3.13/encodings/__init__.py', 'app/certifi/cacert.pem',
                     'app/yt_dlp-1.dist-info/METADATA', 'ThirdPartyNotices.txt', 'app/music_engine.py']
            for path in paths:
                target = app / path; target.parent.mkdir(parents=True, exist_ok=True); target.write_text('keep')
            embed.trim_development_resources(app)
            self.assertFalse((app / paths[0]).exists())
            for path in paths[1:]: self.assertEqual((app / path).read_text(), 'keep')


if __name__ == '__main__': unittest.main()
