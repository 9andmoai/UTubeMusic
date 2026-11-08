import importlib.util
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("music_engine", Path(__file__).resolve().parents[1] / "Python/music_engine.py")
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
ID = "AbCdEf123_-"


class EngineTests(unittest.TestCase):
    def test_youtube_and_music_links(self):
        for value in [ID, "youtu.be/" + ID, "https://music.youtube.com/watch?v=" + ID,
                      "https://www.youtube.com/watch?v=" + ID + "&list=anything", "https://youtube.com/shorts/" + ID]:
            with self.subTest(value=value): self.assertEqual(engine.video_id(value), ID)

    def test_reject_lookalike_hosts_and_unsupported_urls(self):
        for value in ["https://youtube.com.evil.example/watch?v=" + ID, "https://evil.example/" + ID,
                      "https://youtube.com@evil.example/watch?v=" + ID, "file:///etc/passwd",
                      "https://youtube.com/playlist?list=123", "https://youtube.com/watch?v=short"]:
            with self.subTest(value=value), self.assertRaises(ValueError): engine.video_id(value)

    def format(self, **values):
        return {"vcodec": "none", "acodec": "mp4a.40.2", "ext": "m4a", "protocol": "https",
                "url": "https://r1.googlevideo.com/videoplayback?expire=123", "abr": 128, **values}

    def info(self, formats):
        return {"id": ID, "title": "Song", "uploader": "Artist", "duration": 180, "formats": formats}

    def test_choose_aac_only_and_keep_audio_metadata(self):
        formats = [self.format(abr=64), self.format(abr=128), self.format(ext="webm", acodec="opus", abr=160),
                   self.format(vcodec="avc1", abr=999)]
        output = engine.select_audio(self.info(formats))
        self.assertEqual(output["bitrate"], 128)
        self.assertEqual(output["song"]["artist"], "Artist")

    def test_no_fake_m4a_for_unsupported_format(self):
        for fmt in [self.format(ext="webm", acodec="opus"), self.format(protocol="m3u8_native"), self.format(has_drm=True), self.format(vcodec="h264")]:
            with self.subTest(fmt=fmt), self.assertRaises(ValueError): engine.select_audio(self.info([fmt]))

    def test_source_and_header_validation(self):
        for url in ["http://r1.googlevideo.com/a", "https://googlevideo.com.evil.example/a", "https://evil.example/a"]:
            with self.subTest(url=url), self.assertRaises(ValueError): engine.select_audio(self.info([self.format(url=url)]))
        info = self.info([self.format(http_headers={"User-Agent": "test", "Cookie": "secret", "Authorization": "secret"})])
        result = engine.select_audio(info)
        self.assertEqual(result["headers"], {"User-Agent": "test"})

    def test_live_is_rejected(self):
        for flag in [{"is_live": True}, {"live_status": "is_upcoming"}]:
            with self.subTest(flag=flag), self.assertRaises(ValueError): engine.select_audio({**self.info([self.format()]), **flag})

    def test_prefers_music_metadata(self):
        song = engine.song({"id": ID, "title": "Uploaded title", "track": "Song title", "artist": "Artist", "uploader": "Channel", "duration": None})
        self.assertEqual(song["title"], "Song title"); self.assertEqual(song["artist"], "Artist"); self.assertEqual(song["duration"], 0)

    def test_search_contract_and_error_does_not_leak_tokens(self):
        queries = []
        class FakeYDL:
            def __init__(self, options): pass
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def extract_info(self, query, download=False):
                queries.append(query)
                if "failure" in query: raise RuntimeError("secret token=abc media URL")
                return {"_type": "playlist", "entries": [{"id": ID, "title": "Song", "duration": 15}, None, {"id": "bad"}]}
        with patch.dict(sys.modules, {"yt_dlp": types.SimpleNamespace(YoutubeDL=FakeYDL), "certifi": types.SimpleNamespace(where=lambda: "ca.pem")}):
            result = json.loads(engine.dispatch(json.dumps({"op": "search", "query": "Song"})))
            self.assertTrue(result["ok"]); self.assertEqual(len(result["songs"]), 1)
            engine.dispatch(json.dumps({"op": "search", "query": "TaylorSwift"}))
            self.assertTrue(queries[-1].startswith("ytsearch21:TaylorSwift"))
            error = engine.dispatch(json.dumps({"op": "search", "query": "failure"}))
            self.assertNotIn("secret", error); self.assertFalse(json.loads(error)["ok"])

    def test_search_pages_use_raw_offsets_and_lookahead_even_when_entries_are_filtered(self):
        calls = []
        class FakeYDL:
            def __init__(self, options): self.options = options
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def extract_info(self, query, download=False):
                calls.append((query, self.options.copy()))
                start = self.options.get("playliststart", 1) - 1
                return {"_type": "playlist", "entries": [
                    {"id": f"{i:011d}", "title": "Song", "is_live": i == 2} for i in range(start, min(start + 21, 43))]}
        with patch.dict(sys.modules, {"yt_dlp": types.SimpleNamespace(YoutubeDL=FakeYDL), "certifi": types.SimpleNamespace(where=lambda: "ca.pem")}):
            first = json.loads(engine.dispatch(json.dumps({"op": "search", "query": "Song"})))
            second = json.loads(engine.dispatch(json.dumps({"op": "search", "query": "Song", "offset": "20"})))
            last = json.loads(engine.dispatch(json.dumps({"op": "search", "query": "Song", "offset": "40"})))
        self.assertEqual(first["next_offset"], 20); self.assertEqual(len(first["songs"]), 19)
        self.assertTrue(first["has_more"]); self.assertTrue(second["has_more"])
        self.assertFalse(last["has_more"]); self.assertEqual(len(last["songs"]), 3)
        self.assertEqual(calls[1][1]["playliststart"], 21); self.assertEqual(calls[1][1]["playlistend"], 41)
        self.assertEqual(calls[1][0], "ytsearch41:Song 音楽")
        self.assertEqual(len({s["id"] for p in [first, second, last] for s in p["songs"]}), 42)

    def test_invalid_search_offset_is_rejected(self):
        with patch.dict(sys.modules, {"yt_dlp": types.SimpleNamespace(YoutubeDL=object), "certifi": types.SimpleNamespace(where=lambda: "ca.pem")}):
            for offset in [-1, 1000, "bad"]:
                result = json.loads(engine.dispatch(json.dumps({"op": "search", "query": "Song", "offset": offset})))
                self.assertFalse(result["ok"])

    def test_official_audio_fallback_requires_explicit_age_gate_and_playback_opt_in(self):
        class DownloadError(Exception): pass
        alternate = "official123"
        finder = Mock(return_value=alternate)
        ydl = Mock()
        with patch.dict(sys.modules, {"yt_dlp.utils": types.SimpleNamespace(DownloadError=DownloadError),
                                      "music_catalog": types.SimpleNamespace(find_official_audio=finder)}):
            for enabled, message in [(False, "Sign in to confirm your age"), (True, "Sign in to confirm you're not a bot"),
                                     (True, "The read operation timed out"), (True, "Not available in your country")]:
                ydl.extract_info.side_effect = DownloadError(message)
                with self.assertRaises(DownloadError):
                    engine.resolve_playback(ydl, ID, enabled)
            finder.assert_not_called()
            ydl.extract_info.side_effect = [DownloadError("Sign in to confirm your age"),
                                            {**self.info([self.format()]), "id": alternate, "age_limit": 0}]
            result = engine.resolve_playback(ydl, ID, True)
            self.assertEqual(result["audio_source_id"], alternate)
            self.assertEqual(result["song"]["id"], alternate)
            finder.assert_called_once_with(ID)

    def test_official_audio_rejects_an_age_restricted_or_mismatched_alternative(self):
        class DownloadError(Exception): pass
        finder = Mock(return_value="official123")
        ydl = Mock()
        with patch.dict(sys.modules, {"yt_dlp.utils": types.SimpleNamespace(DownloadError=DownloadError),
                                      "music_catalog": types.SimpleNamespace(find_official_audio=finder)}):
            for info in [self.info([self.format()]), {**self.info([self.format()]), "id": "official123", "age_limit": 18}]:
                ydl.extract_info.side_effect = [DownloadError("This video is age-restricted"), info]
                with self.assertRaisesRegex(ValueError, "年齢確認"):
                    engine.resolve_playback(ydl, ID, True)
            finder.return_value = None
            ydl.extract_info.reset_mock(side_effect=True)
            ydl.extract_info.side_effect = DownloadError("Sign in to confirm your age")
            with self.assertRaisesRegex(ValueError, "年齢確認"):
                engine.resolve_playback(ydl, ID, True)
            self.assertEqual(ydl.extract_info.call_count, 1)

    def test_preview_uses_named_chorus_and_respects_chapter_end(self):
        result = engine.preview_window({"duration": 200, "chapters": [
            {"title": "Pre-Chorus", "start_time": 30},
            {"title": "サビ", "start_time": 48, "end_time": 58}]})
        self.assertEqual(result, {"preview_start": 48, "preview_end": 58, "preview_kind": "chorus"})

    def test_preview_fallback_short_unknown_and_invalid_chapters(self):
        for duration, start, end in [(200, 80, 95), (20, 5, 20), (7, 0, 7), (None, 0, 15)]:
            result = engine.preview_window({"duration": duration, "chapters": [None,
                {"title": "サビ前", "start_time": 2}, {"title": "Chorus", "start_time": float("nan")},
                {"title": "Chorus", "start_time": -1}]})
            self.assertEqual((result["preview_start"], result["preview_end"]), (start, end))
            self.assertNotEqual(result["preview_kind"], "chorus")
        self.assertEqual(engine.preview_window({"duration": 30, "chapters": [
            {"title": "Chorus", "start_time": 100}]} )["preview_start"], 12)

    def test_preview_resolves_without_download_or_lower_quality(self):
        calls = []
        info = self.info([self.format(abr=64), self.format(abr=128)])
        class FakeYDL:
            def __init__(self, options): calls.append(options)
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def extract_info(self, query, download):
                calls.append((query, download)); return info
        with patch.dict(sys.modules, {"yt_dlp": types.SimpleNamespace(YoutubeDL=FakeYDL), "certifi": types.SimpleNamespace(where=lambda: "ca.pem")}):
            result = json.loads(engine.dispatch(json.dumps({"op": "preview", "id": ID})))
        self.assertTrue(result["ok"]); self.assertEqual(result["bitrate"], 128)
        self.assertEqual(result["song"], engine.song(info)); self.assertTrue(calls[0]["skip_download"])
        self.assertFalse(calls[1][1]); self.assertEqual(result["preview_end"] - result["preview_start"], 15)


if __name__ == "__main__": unittest.main()
