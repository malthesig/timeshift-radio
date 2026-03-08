from __future__ import annotations

import json
import os
import re
from datetime import datetime, date
from typing import Optional
from zoneinfo import ZoneInfo

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
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
    {"slug": "p6-beat",  "name": "P6 Beat",    "description": "Alternativ musik"},
    {"slug": "p7-mix",   "name": "P7 Mix",     "description": "Nostalgisk musik"},
    {"slug": "p8-jazz",  "name": "P8 Jazz",    "description": "Jazz"},
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
async def now_playing(channel: str = "p1", user_tz: str = "America/Los_Angeles"):
    """
    Given a channel and user timezone, find what's 'now playing' using time-shift logic:
    play what aired in Copenhagen at the same wall-clock time as the user's current time.
    """
    try:
        tz = ZoneInfo(user_tz)
    except Exception:
        raise HTTPException(400, f"Unknown timezone: {user_tz}")

    now_local = datetime.now(tz)

    # Interpret the user's current wall-clock time as Copenhagen local time
    target_cph = now_local.replace(tzinfo=COPENHAGEN_TZ)
    target_utc = target_cph.astimezone(ZoneInfo("UTC"))

    # Determine which date to fetch the schedule for (Copenhagen calendar date)
    schedule_date = target_cph.date()

    try:
        items = await fetch_schedule(channel, schedule_date)
    except Exception as e:
        raise HTTPException(502, f"Failed to fetch schedule: {e}")

    show = find_show_at_time(items, target_utc)

    if not show:
        return {
            "status": "no_show",
            "message": "No show found for this time slot",
            "target_cph_time": target_cph.strftime("%H:%M"),
            "schedule_date": str(schedule_date),
        }

    return {
        "status": "ok",
        "channel": channel,
        "target_cph_time": target_cph.strftime("%H:%M"),
        "schedule_date": str(schedule_date),
        "show": {
            "title": show.get("title"),
            "description": show.get("description"),
            "startTime": show.get("startTime"),
            "endTime": show.get("endTime"),
            "isAvailableOnDemand": show.get("isAvailableOnDemand"),
            "presentationUrl": show.get("presentationUrl"),
            "imageAssets": show.get("imageAssets", []),
            "id": show.get("id"),
        },
        "user": {
            "timezone": user_tz,
            "localTime": now_local.strftime("%H:%M"),
            "localDate": now_local.strftime("%Y-%m-%d"),
        }
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

    # Resolve the assetlinks redirect to get the actual CDN URL
    async with httpx.AsyncClient(headers=HEADERS, follow_redirects=False, timeout=10) as client:
        resp = await client.get(asset_url)

    if resp.status_code in (301, 302, 303, 307, 308):
        cdn_url = resp.headers.get("location", asset_url)
    else:
        cdn_url = asset_url

    return {"url": cdn_url, "format": best.get("format"), "bitrate": best.get("bitrate")}


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8888))
    uvicorn.run("app:app", host="0.0.0.0", port=port, loop="asyncio", http="h11")
