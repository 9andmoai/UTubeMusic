"""Public YouTube Music metadata. No Google login, cookies from users, or paid API."""
import re
import unicodedata
import urllib.parse


def playback_metadata(ident, format_id=None):
    """Optional source reference level; failure must never block playback."""
    try:
        from ytmusicapi import YTMusic
        import requests
        import certifi
        from functools import partial
        with requests.Session() as session:
            session.trust_env = False
            session.verify = certifi.where()
            session.request = partial(session.request, timeout=3)
            data = YTMusic(requests_session=session).get_song(ident)
            return {"loudness_db": loudness_value(data), "audio_duration": audio_duration(data, format_id)}
    except Exception:
        return {}


def audio_duration(data, format_id):
    """AAC format duration in milliseconds; never use the rounded video length."""
    import math
    if not format_id:
        return None
    ident = str(format_id).split("-")[0]
    try:
        for value in data.get("streamingData", {}).get("adaptiveFormats", []):
            if not isinstance(value, dict) or str(value.get("itag")) != ident or not str(value.get("mimeType", "")).startswith("audio/mp4"):
                continue
            raw = value.get("approxDurationMs")
            if isinstance(raw, bool):
                continue
            seconds = float(raw) / 1000
            if math.isfinite(seconds) and 0 < seconds <= 86400:
                return seconds
    except (TypeError, ValueError, AttributeError, OverflowError):
        pass
    return None


def loudness_value(data):
    import math
    try:
        values = [data.get("playerConfig", {}).get("audioConfig", {}).get("loudnessDb")]
        values += [f.get("loudnessDb") for f in data.get("streamingData", {}).get("adaptiveFormats", [])
                   if isinstance(f, dict) and str(f.get("mimeType", "")).startswith("audio/mp4")]
        for value in values:
            if value is None or isinstance(value, bool):
                continue
            try:
                value = float(value)
            except (TypeError, ValueError, OverflowError):
                continue
            if math.isfinite(value) and -60 <= value <= 60:
                return value
    except (AttributeError, TypeError):
        pass
    return None


def thumbnail(value):
    return next((t["url"] for t in reversed(value.get("thumbnails") or [])
                 if str(t.get("url", "")).startswith("https://")), None)


def names(value):
    if isinstance(value, str):
        return value
    return " / ".join(v.get("name", "") for v in (value or []) if isinstance(v, dict))


def item(value):
    browse = value.get("browseId", "") or ""
    ident = browse if browse.startswith("MPRE") else value.get("playlistId") or browse
    if ident.startswith("VL"):
        ident = ident[2:]
    kind = "album" if ident.startswith("MPRE") else "playlist"
    if not re.fullmatch(r"[A-Za-z0-9_-]{5,200}", ident) or (kind == "playlist" and not ident.startswith(("PL", "OLAK", "RD"))):
        return None
    return {"id": ident, "kind": kind, "title": value.get("title") or "タイトル不明",
            "subtitle": names(value.get("artists") or value.get("author")) or ("アルバム" if kind == "album" else "プレイリスト"),
            "thumbnail": thumbnail(value)}


def collection_ref(value):
    if not isinstance(value, str):
        raise ValueError("プレイリストのリンクを確認してください。")
    if "://" in value or "/" in value:
        parsed = urllib.parse.urlparse(value if "://" in value else "https://" + value)
        if parsed.scheme != "https" or parsed.username or parsed.password or parsed.hostname not in ("music.youtube.com", "www.youtube.com", "youtube.com", "m.youtube.com"):
            raise ValueError("YouTubeの公開プレイリスト・アルバムのリンクを入力してください。")
        value = parsed.path.removeprefix("/browse/") if parsed.path.startswith("/browse/") else urllib.parse.parse_qs(parsed.query).get("list", [""])[0]
    if value.startswith("VL"):
        value = value[2:]
    if not re.fullmatch(r"(?:MPRE|PL|OLAK|RD)[A-Za-z0-9_-]{1,196}", value):
        raise ValueError("公開プレイリスト・アルバムのリンクを確認してください。")
    return value


def normalized_title(value):
    return " ".join(unicodedata.normalize("NFKC", value or "").casefold().split())


def artist_ids(track):
    artists = track.get("artists") or []
    return {artist["id"] for artist in artists} if artists and all(artist.get("id") for artist in artists) else set()


def official_audio_candidate(api, ident):
    tracks = api.get_watch_playlist(videoId=ident, limit=1).get("tracks") or []
    if not tracks or tracks[0].get("videoId") != ident:
        return None
    original = tracks[0]
    if original.get("videoType") not in ("MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_ATV"):
        return None
    counterpart = original.get("counterpart") or {}
    counterpart_id = counterpart.get("videoId") or ""
    # A Song/Video pair from the catalog identifies the official audio directly.
    if counterpart_id != ident and re.fullmatch(r"[A-Za-z0-9_-]{11}", counterpart_id) and counterpart.get("videoType") == "MUSIC_VIDEO_TYPE_ATV":
        return counterpart_id

    title = normalized_title(original.get("title"))
    artists = artist_ids(original)
    length = (original.get("length") or "").split(":")
    if not title or not artists or not 2 <= len(length) <= 3 or not all(part.isascii() and part.isdigit() for part in length):
        return None
    duration = sum(int(part) * 60 ** index for index, part in enumerate(reversed(length)))
    if duration <= 0:
        return None
    query = original["title"] + " " + names(original["artists"])
    matches = {}
    for candidate in api.search(query, filter="songs", limit=10)[:10]:
        source = candidate.get("videoId") or ""
        seconds = candidate.get("duration_seconds")
        if (source != ident and re.fullmatch(r"[A-Za-z0-9_-]{11}", source)
                and candidate.get("videoType") == "MUSIC_VIDEO_TYPE_ATV"
                and (candidate.get("album") or {}).get("id")
                and normalized_title(candidate.get("title")) == title and artist_ids(candidate) == artists
                and type(seconds) is int and seconds > 0
                and abs(seconds - duration) <= min(30, max(5, duration * 0.1))):
            matches[source] = seconds
    # A single and album version can have different IDs. If their running times
    # differ materially, avoid choosing a recording based on search rank.
    if matches and max(matches.values()) - min(matches.values()) <= 3:
        return next(iter(matches))
    return None


def find_official_audio(ident):
    from ytmusicapi import YTMusic
    import certifi
    import requests
    from functools import partial
    with requests.Session() as session:
        session.trust_env = False
        session.verify = certifi.where()
        session.request = partial(session.request, timeout=5)
        return official_audio_candidate(YTMusic(requests_session=session, location="JP"), ident)


def song_lyrics(api, ident):
    if not isinstance(ident, str) or not re.fullmatch(r"[A-Za-z0-9_-]{11}", ident):
        raise ValueError("YouTubeの曲を選んでください。")
    watch = api.get_watch_playlist(videoId=ident, limit=1)
    tracks = watch.get("tracks") or []
    key = watch.get("lyrics")
    # The endpoint can substitute a different recording. Its timing is not interchangeable.
    if not tracks or tracks[0].get("videoId") != ident or not key:
        return None
    result = api.get_lyrics(key, timestamps=True)
    if not result:
        return None
    raw = result.get("lyrics")
    source = result.get("source")
    if not result.get("hasTimestamps"):
        return {"text": raw.strip(), "source": source} if isinstance(raw, str) and raw.strip() else None

    lines = []
    for line in raw[:1000]:
        if 0 <= line.start_time < line.end_time <= 86_400_000 and line.text.strip():
            lines.append({"text": line.text, "start": line.start_time / 1000, "end": line.end_time / 1000})
    if not lines:
        return None
    return {"lines": sorted(lines, key=lambda line: line["start"]), "source": source}


def dispatch(request):
    from ytmusicapi import YTMusic
    import certifi
    import requests
    from functools import partial
    with requests.Session() as session:
        session.trust_env = False
        session.verify = certifi.where()
        op = request["op"]
        session.request = partial(session.request, timeout=5 if op == "lyrics" else 20)
        # The pinned parser currently misses filtered search shelves in Japanese.
        # Keep home headings Japanese; English metadata parsing preserves song titles.
        api = YTMusic(requests_session=session, language="ja" if op == "home" else "en", location="JP")
        if op == "lyrics":
            return {"ok": True, "lyrics": song_lyrics(api, request.get("id"))}
        if op == "suggestions":
            query = str(request.get("query", "")).strip()[:100]
            return {"ok": True, "suggestions": api.get_search_suggestions(query)[:8] if query and "://" not in query else []}
        if op == "home":
            sections = []
            seen = set()
            for index, row in enumerate(api.get_home(limit=6)):
                values = []
                for raw in row.get("contents", []):
                    entry = item(raw)
                    if entry and entry["id"] not in seen:
                        values.append(entry); seen.add(entry["id"])
                if values:
                    sections.append({"id": str(index), "title": row.get("title") or "見つける", "items": values[:20]})
            return {"ok": True, "sections": sections}
        if op == "catalog_search":
            kind = request.get("kind")
            if kind not in ("albums", "playlists"):
                raise ValueError("アルバムかプレイリストを選んでください。")
            offset = int(request.get("offset", 0))
            if not 0 <= offset < 200:
                raise ValueError("検索条件を変えて探してください。")
            values = [v for raw in api.search(str(request.get("query", ""))[:200], filter=kind, limit=offset + 21) if (v := item(raw))]
            return {"ok": True, "items": values[offset:offset + 20], "has_more": len(values) > offset + 20 and offset + 20 < 200, "next_offset": offset + 20}
        if op == "collection":
            ident = collection_ref(request.get("id", ""))
            album = ident.startswith("MPRE")
            data = api.get_album(ident) if album else api.get_playlist(ident, limit=1001)
            tracks = data.get("tracks") or []
            if len(tracks) > 1000 or int(data.get("trackCount") or len(tracks)) > 1000:
                raise ValueError("1000曲を超えるリストです。小さいプレイリストに分けてください。")
            songs, seen = [], set()
            for track in tracks:
                video = track.get("videoId", "") or ""
                if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video) or track.get("isAvailable") is False or video in seen:
                    continue
                seen.add(video)
                songs.append({"id": video, "title": track.get("title") or "タイトル不明",
                              "artist": names(track.get("artists") or data.get("artists")) or "アーティスト不明",
                              "duration": track.get("duration_seconds") or 0, "thumbnail": thumbnail(track) or thumbnail(data)})
            return {"ok": True, "collection": {"id": ident, "kind": "album" if album else "playlist",
                    "title": data.get("title") or "プレイリスト", "subtitle": names(data.get("artists") or data.get("author")),
                    "thumbnail": thumbnail(data)}, "songs": songs, "unavailable": max(0, len(tracks) - len(songs))}
    raise ValueError("未対応の操作です。")
