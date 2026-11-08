"""On-device metadata/search only. Swift transfers and validates the audio.

No account, API key, remote helper, subprocess or FFmpeg is used here.
WebKit challenge support is experimental and must be tested on an actual iPhone.
"""
import json
import math
import re
import urllib.parse

VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")


def webkit_selftest():
    from yt_dlp_plugins.webkit_jsi.lib.easy import WKJSE_Factory, WKJSE_Webview
    from yt_dlp_plugins.webkit_jsi.lib.logging import DefaultLoggerImpl
    messages = []
    with WKJSE_Factory(DefaultLoggerImpl()) as send, WKJSE_Webview(send) as webview:
        webview.on_script_log(messages.append)
        webview.execute_js("console.log(6 * 7)")
    if not any(message.get("argsArr") == [42] for message in messages):
        raise RuntimeError("Embedded WebKit did not return the expected JavaScript result")


def video_id(value):
    value = value.strip()
    if VIDEO_ID.fullmatch(value):
        return value
    if "://" not in value:
        value = "https://" + value
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme not in ("https", "http") or parsed.username or parsed.password:
        raise ValueError("YouTubeの曲のリンクを入力してください。")
    host = (parsed.hostname or "").lower()
    if host in ("youtu.be", "www.youtu.be"):
        candidate = parsed.path.strip("/").split("/")[0]
    elif host in ("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"):
        parts = parsed.path.strip("/").split("/")
        candidate = parts[1] if len(parts) > 1 and parts[0] in ("shorts", "live", "embed") else urllib.parse.parse_qs(parsed.query).get("v", [""])[0]
    else:
        raise ValueError("YouTubeの曲のリンクを入力してください。")
    if not VIDEO_ID.fullmatch(candidate):
        raise ValueError("曲単体のリンクを入力してください。プレイリストURLには対応していません。")
    return candidate


def song(info):
    ident = str(info.get("id", ""))
    if not VIDEO_ID.fullmatch(ident):
        raise ValueError("曲のIDを取得できませんでした。")
    thumbnails = info.get("thumbnails") or []
    thumbnail = info.get("thumbnail") or next((x["url"] for x in reversed(thumbnails) if x.get("url")), None)
    return {"id": ident, "title": info.get("track") or info.get("title") or "タイトル不明",
            "artist": info.get("artist") or info.get("uploader") or info.get("channel") or "アーティスト不明",
            "duration": info.get("duration") or 0, "thumbnail": thumbnail}


def select_audio(info):
    """Only directly playable AAC in MP4; don't download video or an Opus file as M4A."""
    if info.get("is_live") or info.get("live_status") in ("is_live", "is_upcoming"):
        raise ValueError("配信中・公開前の曲は保存できません。")
    formats = [f for f in info.get("formats", [])
               if f.get("vcodec") == "none" and f.get("ext") == "m4a"
               and (f.get("acodec") or "").startswith("mp4a")
               and f.get("protocol") == "https" and f.get("url") and not f.get("has_drm")]
    if not formats:
        raise ValueError("iPhoneで保存できるAAC音声が見つかりません。取得元の制限や仕様変更の可能性があります。")
    selected = max(formats, key=lambda f: f.get("abr") or f.get("tbr") or 0)
    url = selected["url"]
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or not (parsed.hostname or "").endswith(".googlevideo.com"):
        raise ValueError("安全な音声の保存先を確認できませんでした。")
    headers = dict(info.get("http_headers") or {})
    headers.update(selected.get("http_headers") or {})
    # No account cookies are collected or forwarded by this app.
    headers = {k: str(v) for k, v in headers.items() if k.lower() in ("user-agent", "referer", "origin", "accept", "accept-language")}
    return {"song": song(info), "url": url, "headers": headers,
            "audio_format_id": selected.get("format_id"),
            "bytes": selected.get("filesize") or 0, "bitrate": selected.get("abr") or 0}


def preview_window(info):
    """Use explicitly named chorus chapters; otherwise say honestly that it is a middle excerpt."""
    def number(value):
        try:
            value = float(value)
            return value if math.isfinite(value) and value >= 0 else None
        except (TypeError, ValueError):
            return None
    duration = number(info.get("duration")) or 0
    start = max(0, min(duration * 0.4, duration - 15)) if duration > 15 else 0
    kind = "middle" if start > 0 else "beginning"
    end = min(duration, start + 15) if duration else 15
    for chapter in info.get("chapters") or []:
        if not isinstance(chapter, dict):
            continue
        title = str(chapter.get("title") or "")
        if not re.search(r"\b(?:chorus|refrain)\b|サビ", title, re.I) or re.search(r"pre[- ]?chorus|サビ前", title, re.I):
            continue
        value = number(chapter.get("start_time"))
        if value is None or (duration and value >= duration):
            continue
        start = value
        end = min(start + 15, duration) if duration else start + 15
        chapter_end = number(chapter.get("end_time"))
        if chapter_end is not None and chapter_end > start:
            end = min(end, chapter_end)
        kind = "chorus"
        break
    return {"preview_start": start, "preview_end": end, "preview_kind": kind}


def dispatch(request_json):
    try:
        request = json.loads(request_json)
        if request.get("op") in ("home", "catalog_search", "collection", "suggestions", "lyrics"):
            import music_catalog
            return json.dumps(music_catalog.dispatch(request), ensure_ascii=False)
        import certifi
        from yt_dlp import YoutubeDL
        options = {"quiet": True, "no_warnings": True, "skip_download": True,
                   "cachedir": False, "noplaylist": True, "socket_timeout": 25,
                   "retries": 1, "extractor_retries": 1, "nocheckcertificate": False,
                   "ca_certs": certifi.where()}
        op = request.get("op")
        if op == "selftest":
            # Runs in the iOS simulator test host without accessing the network.
            # These imports exercise the packaged native extension loader as well.
            import ssl
            import ctypes
            from ytmusicapi import YTMusic
            YTMusic(language="ja", location="JP")  # Constructor must work offline inside iOS.
            with YoutubeDL(options):
                pass
            import sys
            # Let yt-dlp load providers once; a premature direct import double-registers them.
            provider = sys.modules.get("yt_dlp_plugins.extractor.ytjsc")
            if provider is None or not hasattr(provider, "AppleWebKitJCP"):
                raise RuntimeError("The on-device JavaScript provider was not loaded")
            webkit_selftest()
            return json.dumps({"ok": True, "songs": []})
        if op == "search":
            query = str(request.get("query", "")).strip()[:200]
            if not query:
                return json.dumps({"ok": True, "songs": [], "has_more": False, "next_offset": 0})
            offset = int(request.get("offset", 0))
            if not 0 <= offset < 1000:
                raise ValueError("検索条件を変えて、さらに曲を探してください。")
            page_size = min(20, 1000 - offset)
            ident = None
            if "://" in query or query.startswith(("youtube.com/", "www.youtube.com/", "music.youtube.com/", "m.youtube.com/", "youtu.be/")):
                try:
                    ident = video_id(query)
                except ValueError:
                    raise ValueError("YouTubeの曲単体のリンクを確認してください。")
            options["extract_flat"] = "in_playlist"
            if not ident:
                # One look-ahead item determines whether another page exists. yt-dlp
                # consumes YouTube continuations, not an artificial first-20 limit.
                options["playliststart"] = offset + 1
                options["playlistend"] = offset + page_size + 1
            with YoutubeDL(options) as ydl:
                data = ydl.extract_info("https://www.youtube.com/watch?v=" + ident if ident else f"ytsearch{offset + page_size + 1}:" + query + " 音楽", download=False)
            entries = list(data.get("entries", [])) if data.get("_type") in ("playlist", "multi_video") else [data]
            has_more = not ident and len(entries) > page_size and offset + page_size < 1000
            consumed = min(len(entries), page_size)
            songs = []
            seen = set()
            for entry in entries[:page_size]:
                if not entry or entry.get("is_live"):
                    continue
                try:
                    value = song(entry)
                    if value["id"] not in seen:
                        songs.append(value)
                        seen.add(value["id"])
                except ValueError:
                    continue
            return json.dumps({"ok": True, "songs": songs, "has_more": has_more,
                               "next_offset": offset + consumed}, ensure_ascii=False)
        if op in ("resolve", "preview"):
            ident = video_id(str(request.get("id", "")))
            with YoutubeDL(options) as ydl:
                info = ydl.extract_info("https://www.youtube.com/watch?v=" + ident, download=False)
            result = {"ok": True, **select_audio(info)}
            import music_catalog
            result.update(music_catalog.playback_metadata(ident, result.get("audio_format_id")))
            if op == "preview":
                result.update(preview_window(info))
            return json.dumps(result, ensure_ascii=False)
        raise ValueError("未対応の操作です。")
    except Exception as exc:
        # Do not expose expiring media URLs, tokens or a Python traceback to the UI.
        if isinstance(locals().get("request"), dict) and request.get("op") == "selftest":
            message = type(exc).__name__ + ": " + str(exc)
        else:
            message = str(exc) if isinstance(exc, ValueError) else "取得元から曲を読み込めませんでした。通信を確認して再試行してください。取得制限や仕様変更が原因の場合もあります。"
        return json.dumps({"ok": False, "error": message}, ensure_ascii=False)
