from __future__ import annotations

import json
import os
import re
from datetime import datetime, date, timedelta
from typing import Optional
from zoneinfo import ZoneInfo

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, StreamingResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from fastapi.requests import Request

app = FastAPI()
templates = Jinja2Templates(directory="templates")

DR_CHANNELS = [
    {"slug": "p1",       "name": "P1",        "description": "Nyheder & kultur"},
    {"slug": "p2",       "name": "P2 Klassisk","description": "Klassisk musik"},
    {"slug": "p3",       "name": "P3",         "description": "Pop & rock"},
    {"slug": "p4",       "name": "P4",         "description": "Regional radio"},
    {"slug": "p5",       "name": "P5",         "description": "Klassiske hits"},
    {"slug": "p6beat",   "name": "P6 Beat",    "description": "Alternativ musik"},
    # P7 Mix removed: no schedule URL on DR LYD (live-only stream, no on-demand)
    {"slug": "p8jazz",   "name": "P8 Jazz",    "description": "Jazz"},
]

COPENHAGEN_TZ = ZoneInfo("Europe/Copenhagen")
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept-Language": "da-DK,da;q=0.9,en-US;q=0.8",
}


def extract_next_data(html: str) -> dict:
    """Extract __NEXT_DATA__ JSON from a DR LYD HTML page."""
    match = re.search(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', html, re.DOTALL)
    if not match:
        raise ValueError("Could not find __NEXT_DATA__ in page")
    return json.loads(match.group(1))


async def fetch_schedule(channel_slug: str, target_date: date) -> list[dict]:
    """Fetch schedule items for a channel on a given date."""
    date_str = target_date.strftime("%Y-%m-%d")
    url = f"https://www.dr.dk/lyd/{channel_slug}/{date_str}"
    async with httpx.AsyncClient(headers=HEADERS, follow_redirects=True, timeout=15) as client:
        resp = await client.get(url)
        resp.raise_for_status()
    data = extract_next_data(resp.text)
    items = data.get("props", {}).get("pageProps", {}).get("schedule", {}).get("items", [])
    return items


async def fetch_episode_audio(presentation_url: str) -> list[dict]:
    """Fetch audio assets for an episode from its presentation URL."""
    async with httpx.AsyncClient(headers=HEADERS, follow_redirects=True, timeout=15) as client:
        resp = await client.get(presentation_url)
        resp.raise_for_status()
    data = extract_next_data(resp.text)
    episode = data.get("props", {}).get("pageProps", {}).get("episode", {})
    return episode.get("audioAssets", [])


def find_show_at_time(items: list[dict], target_utc: datetime) -> Optional[dict]:
    """Find the schedule item airing at the given UTC time."""
    for item in items:
        start = datetime.fromisoformat(item["startTime"])
        end = datetime.fromisoformat(item["endTime"])
        if start <= target_utc < end:
            return item
    return None


def find_next_show(items: list[dict], current_show: dict) -> Optional[dict]:
    """Find the show immediately following the current one."""
    current_end = datetime.fromisoformat(current_show["endTime"])
    for item in items:
        start = datetime.fromisoformat(item["startTime"])
        if start >= current_end:
            return item
    return None


def find_previous_show(items: list[dict], current_show: dict) -> Optional[dict]:
    """Find the show immediately before the current one."""
    current_start = datetime.fromisoformat(current_show["startTime"])
    best = None
    for item in items:
        end = datetime.fromisoformat(item["endTime"])
        if end <= current_start:
            if best is None or datetime.fromisoformat(best["endTime"]) < end:
                best = item
    return best


def wall_clock_as_copenhagen(user_dt: datetime) -> datetime:
    """
    Take the user's wall-clock time (H:MM) and return a datetime representing
    that same H:MM in Copenhagen on the same calendar date.
    """
    return user_dt.replace(tzinfo=COPENHAGEN_TZ)


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse("index.html", {
        "request": request,
        "channels": DR_CHANNELS,
    })


@app.get("/api/now")
async def now_playing(channel: str = "p1", user_tz: str = "America/Los_Angeles",
                      at: Optional[str] = None):
    """
    Given a channel and user timezone, find what's 'now playing' using time-shift logic:
    play what aired in Copenhagen at the same wall-clock time as the user's current time.

    Optional `at` parameter: a UTC ISO datetime string (e.g. "2026-03-08T19:03:00+00:00").
    When provided, look up the show at that specific time instead of computing from the
    user's current wall-clock time. Used for Prev/Next navigation.
    """
    if at:
        try:
            target_utc = datetime.fromisoformat(at)
            if target_utc.tzinfo is None:
                target_utc = target_utc.replace(tzinfo=ZoneInfo("UTC"))
        except ValueError:
            raise HTTPException(400, f"Invalid 'at' parameter: {at}")
        target_cph = target_utc.astimezone(COPENHAGEN_TZ)
    else:
        try:
            tz = ZoneInfo(user_tz)
        except Exception:
            raise HTTPException(400, f"Unknown timezone: {user_tz}")
        now_local = datetime.now(tz)
        target_cph = now_local.replace(tzinfo=COPENHAGEN_TZ)
        target_utc = target_cph.astimezone(ZoneInfo("UTC"))

    # Determine which date to fetch the schedule for (Copenhagen calendar date)
    schedule_date = target_cph.date()

    try:
        items = await fetch_schedule(channel, schedule_date)
    except Exception as e:
        raise HTTPException(502, f"Failed to fetch schedule: {e}")

    show = find_show_at_time(items, target_utc)

    # Nothing found on today's schedule — a show may have started before midnight
    # and still be airing now (e.g. 23:45 start, 00:30 end). Check yesterday too.
    if not show:
        try:
            prev_items = await fetch_schedule(channel, schedule_date - timedelta(days=1))
            show = find_show_at_time(prev_items, target_utc)
            if show:
                items = prev_items  # use yesterday's list for next_show lookup too
        except Exception:
            pass

    if not show:
        return {
            "status": "no_show",
            "message": "No show found for this time slot",
            "target_cph_time": target_cph.strftime("%H:%M"),
            "schedule_date": str(schedule_date),
        }

    def show_dict(s: dict) -> dict:
        return {
            "title": s.get("title"),
            "description": s.get("description"),
            "startTime": s.get("startTime"),
            "endTime": s.get("endTime"),
            "isAvailableOnDemand": s.get("isAvailableOnDemand"),
            "presentationUrl": s.get("presentationUrl"),
            "imageAssets": s.get("imageAssets", []),
            "id": s.get("id"),
        }

    prev_show = find_previous_show(items, show)
    next_show = find_next_show(items, show)

    # How many seconds into the show the listener should start.
    # If the user's wall-clock is 22:33 and the show started at 22:03, this is 1800 s.
    # When `at` is provided (manual navigation) the offset is always 0 because
    # target_utc == show.startTime.
    show_start = datetime.fromisoformat(show.get("startTime"))
    playback_offset = max(0, int((target_utc - show_start).total_seconds()))

    return {
        "status": "ok",
        "channel": channel,
        "target_cph_time": target_cph.strftime("%H:%M"),
        "schedule_date": str(schedule_date),
        "navigated": at is not None,
        "playback_offset_seconds": playback_offset,
        "show": show_dict(show),
        "previous_show": show_dict(prev_show) if prev_show else None,
        "next_show": show_dict(next_show) if next_show else None,
        "user": None if at else {
            "timezone": user_tz,
            "localTime": now_local.strftime("%H:%M"),
            "localDate": now_local.strftime("%Y-%m-%d"),
        },
    }


@app.get("/api/stream")
async def get_stream(presentation_url: str, bitrate: int = 192):
    """
    Given an episode's presentationUrl, resolve and return the best audio stream URL.
    Redirects the client directly to the CDN audio file.
    """
    try:
        assets = await fetch_episode_audio(presentation_url)
    except Exception as e:
        raise HTTPException(502, f"Failed to fetch episode: {e}")

    if not assets:
        raise HTTPException(404, "No audio assets found for this episode")

    # Prefer mp3 > mp4, then closest to requested bitrate
    def score(a):
        fmt_score = 0 if a.get("format") == "mp3" else 1
        bitrate_diff = abs(a.get("bitrate", 0) - bitrate)
        return (fmt_score, bitrate_diff)

    best = min(assets, key=score)
    asset_url = best["url"]

    # Resolve the assetlinks redirect to get the actual CDN URL.
    # Must include Referer so DR's API grants the redirect.
    dr_headers = {**HEADERS, "Referer": "https://www.dr.dk/", "Origin": "https://www.dr.dk"}
    async with httpx.AsyncClient(headers=dr_headers, follow_redirects=False, timeout=10) as client:
        resp = await client.get(asset_url)

    if resp.status_code in (301, 302, 303, 307, 308):
        cdn_url = resp.headers.get("location", asset_url)
    elif resp.status_code >= 400:
        raise HTTPException(resp.status_code, "Audio not available for this episode")
    else:
        cdn_url = asset_url

    return {"url": cdn_url, "format": best.get("format"), "bitrate": best.get("bitrate")}


@app.get("/api/proxy-stream")
async def proxy_stream(presentation_url: str, bitrate: int = 192):
    """
    Resolve the assetlinks URL server-side (requires EU IP + Referer),
    then redirect the browser directly to the Akamai CDN URL.
    This gives the browser proper Content-Length / range support so the
    audio player shows duration and seeking works (no "Live Broadcast").
    """
    try:
        assets = await fetch_episode_audio(presentation_url)
    except Exception as e:
        raise HTTPException(502, f"Failed to fetch episode: {e}")

    if not assets:
        raise HTTPException(404, "No audio assets found for this episode")

    def score(a):
        fmt_score = 0 if a.get("format") == "mp3" else 1
        bitrate_diff = abs(a.get("bitrate", 0) - bitrate)
        return (fmt_score, bitrate_diff)

    best = min(assets, key=score)
    asset_url = best["url"]

    dr_headers = {**HEADERS, "Referer": "https://www.dr.dk/", "Origin": "https://www.dr.dk"}

    # Resolve the assetlinks redirect to get the real Akamai CDN URL
    async with httpx.AsyncClient(headers=dr_headers, follow_redirects=False, timeout=20) as client:
        resp = await client.get(asset_url)

    if resp.status_code in (301, 302, 303, 307, 308):
        cdn_url = resp.headers.get("location", asset_url)
    elif resp.status_code >= 400:
        raise HTTPException(resp.status_code, "Audio not available for this episode")
    else:
        cdn_url = asset_url

    # Redirect browser straight to the CDN — no proxying, no timeouts,
    # proper Content-Length so the player shows duration instead of "Live Broadcast"
    return RedirectResponse(cdn_url, status_code=302)


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8888))
    uvicorn.run("app:app", host="0.0.0.0", port=port, loop="asyncio", http="h11")
