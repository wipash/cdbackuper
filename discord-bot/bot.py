#!/usr/bin/env python3
import discord
import os
import re
import json
import aiohttp
from pathlib import Path

DATA_ROOT = os.getenv("DATA_ROOT", "/data")
BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")
DISCORD_WEBHOOK_URL = os.getenv("DISCORD_WEBHOOK_URL")
DEBUG = os.getenv("DEBUG", "false").lower() in ("true", "1", "yes")

def log(msg):
    print(f"[DEBUG] {msg}" if DEBUG else msg)

if not BOT_TOKEN:
    print("ERROR: DISCORD_BOT_TOKEN not set")
    exit(1)

intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)


def sanitize_label(text):
    """Sanitize label text: keep [a-zA-Z0-9_. -], replace spaces with _."""
    first_line = text.strip().split("\n")[0]
    sanitized = re.sub(r'[^a-zA-Z0-9_. -]', '', first_line)
    return sanitized.replace(' ', '_')


def maybe_rename_folder(disc_path, raw_label):
    """Rename disc folder if processing is complete. Returns new Path or None."""
    status_file = disc_path / "status.json"
    if not status_file.exists():
        return None

    try:
        status = json.loads(status_file.read_text())
    except (json.JSONDecodeError, OSError):
        return None

    # Don't rename while importer is still processing — it will rename at completion
    if status.get("status") == "in_progress":
        return None

    uuid = status.get("uuid", "")
    started = status.get("started", "")
    sanitized = sanitize_label(raw_label)
    if not sanitized:
        return None

    # Compute new folder name
    if uuid:
        new_name = f"{uuid}_{sanitized}"
    elif started:
        new_name = f"{started}_{sanitized}"
    else:
        return None

    new_path = disc_path.parent / new_name
    if disc_path == new_path:
        return None
    if new_path.exists():
        log(f"⚠️ Target folder already exists: {new_path}")
        return None

    try:
        disc_path.rename(new_path)
        log(f"📁 Renamed {disc_path.name} → {new_path.name}")
        return new_path
    except OSError as e:
        log(f"⚠️ Could not rename folder: {e}")
        return None


async def update_discord_embed(disc_path):
    """Update the Discord webhook message with the new label and path."""
    if not DISCORD_WEBHOOK_URL:
        return

    status_file = disc_path / "status.json"
    if not status_file.exists():
        return

    try:
        status = json.loads(status_file.read_text())
    except (json.JSONDecodeError, OSError):
        return

    message_id = status.get("discord_message_id", "")
    if not message_id:
        return

    folder_name = disc_path.name
    unc_path = f"\\\\brian\\Backup\\Maurice\\cd-archive\\{folder_name}"
    node = status.get("node", "unknown")
    rescued_pct = status.get("ddrescue", {}).get("rescued_pct", "unknown")
    read_errors = status.get("ddrescue", {}).get("read_errors", "0")
    is_retry = status.get("is_retry", False)
    status_val = status.get("status", "")

    # Read user label
    label_file = disc_path / "label.txt"
    label_text = label_file.read_text().strip() if label_file.exists() else folder_name

    retry_info = ""
    if is_retry:
        retry_nodes = status.get("retry_nodes", [])
        if retry_nodes:
            retry_info = f"\n🔄 **Retry attempt** (Previous: {', '.join(retry_nodes)})"
        else:
            retry_info = "\n🔄 **Retry attempt**"

    if status_val == "success":
        color = 3066993  # Green
        title = "✅ CD Archived Successfully"
        description = (
            f"**Node:** {node}\n"
            f"**Label:** {label_text}\n"
            f"**Rescued:** {rescued_pct}{retry_info}\n"
            f"**Path:** `{unc_path}`\n\n"
            f"💬 *Reply to add disc label*"
        )
    else:
        color = 15158332  # Red
        title = "❌ CD Archive Failed/Partial"
        description = (
            f"**Node:** {node}\n"
            f"**Label:** {label_text}\n"
            f"**Rescued:** {rescued_pct}\n"
            f"**Read Errors:** {read_errors}{retry_info}\n"
            f"**Path:** `{unc_path}`"
        )

    payload = {
        "embeds": [{
            "title": title,
            "description": description,
            "color": color,
            "footer": {"text": folder_name},
            "timestamp": status.get("finished", ""),
        }]
    }

    try:
        async with aiohttp.ClientSession() as session:
            url = f"{DISCORD_WEBHOOK_URL}/messages/{message_id}"
            async with session.patch(url, json=payload) as resp:
                if resp.status >= 300:
                    body = await resp.text()
                    log(f"⚠️ Discord PATCH failed ({resp.status}): {body[:200]}")
                else:
                    log(f"✅ Updated Discord embed for {folder_name}")
    except Exception as e:
        log(f"⚠️ Failed to update Discord embed: {e}")


@client.event
async def on_ready():
    log(f"✅ Bot ready as {client.user}")
    log(f"DATA_ROOT: {DATA_ROOT}")
    log(f"DEBUG mode: {DEBUG}")
    log(f"DISCORD_WEBHOOK_URL: {'set' if DISCORD_WEBHOOK_URL else 'not set'}")

@client.event
async def on_message(message):
    if DEBUG:
        log(f"Message received: author={message.author}, content={message.content[:50]}...")

    # Ignore our own messages
    if message.author == client.user:
        if DEBUG:
            log("Ignoring own message")
        return

    # Only care about replies
    if not message.reference:
        if DEBUG:
            log("Not a reply, ignoring")
        return

    if DEBUG:
        log(f"Reply detected to message ID: {message.reference.message_id}")

    # Fetch the message being replied to
    try:
        replied_to = await message.channel.fetch_message(message.reference.message_id)
        if DEBUG:
            log(f"Replied-to message: author={replied_to.author}, webhook_id={replied_to.webhook_id}")
    except Exception as e:
        if DEBUG:
            log(f"Failed to fetch replied-to message: {e}")
        return

    # Only process messages from CD Archiver webhook
    if replied_to.webhook_id is None:
        if DEBUG:
            log("Replied-to message is not from webhook, ignoring")
        return

    # Check if it's from the CD Archiver webhook specifically
    if replied_to.author.name != "CD Archiver":
        if DEBUG:
            log(f"Replied-to message is from wrong webhook (author: {replied_to.author.name}), ignoring")
        return

    if DEBUG:
        log(f"Processing reply to CD Archiver webhook message")
        log(f"Replied-to content: {replied_to.content[:100]}")
        if replied_to.embeds:
            log(f"Replied-to embeds: {len(replied_to.embeds)}")
            log(f"First embed description: {replied_to.embeds[0].description[:100] if replied_to.embeds[0].description else 'None'}")

    # Extract path from the notification
    # Looking for: **Path:** abc-def-123_MY_DISC in description, or footer text
    disc_path = None

    # First try to find **Path:** in content
    path_match = re.search(r'\*\*Path:\*\*\s+(\S+)', replied_to.content)
    if path_match:
        disc_path = path_match.group(1)
        if DEBUG:
            log(f"Found path in content: {disc_path}")

    # Try embed description
    if not disc_path and replied_to.embeds:
        embed = replied_to.embeds[0]
        if embed.description:
            path_match = re.search(r'\*\*Path:\*\*\s+(\S+)', embed.description)
            if path_match:
                disc_path = path_match.group(1)
                if DEBUG:
                    log(f"Found path in embed description: {disc_path}")

        # Try footer as fallback
        if not disc_path and embed.footer and embed.footer.text:
            disc_path = embed.footer.text.strip()
            if DEBUG:
                log(f"Found path in footer: {disc_path}")

    if not disc_path:
        if DEBUG:
            log("Path not found in notification")
        await message.add_reaction("❌")
        await message.reply("Couldn't find path in notification")
        return

    # Strip UNC prefix and backslash path if the regex matched a UNC path
    # e.g. \\brian\Backup\Maurice\cd-archive\UUID_LABEL -> UUID_LABEL
    unc_match = re.match(r'[`\\]+.*cd-archive[\\/]([^`]+)', disc_path)
    if unc_match:
        disc_path = unc_match.group(1).rstrip('`')
        if DEBUG:
            log(f"Extracted folder name from UNC path: {disc_path}")

    full_path = Path(DATA_ROOT) / disc_path

    if DEBUG:
        log(f"Extracted path: {disc_path}")
        log(f"Full path: {full_path}")

    # Verify directory exists
    if not full_path.exists():
        if DEBUG:
            log(f"Directory does not exist: {full_path}")
        await message.add_reaction("❌")
        await message.reply(f"Directory not found: {disc_path}")
        return

    if DEBUG:
        log(f"Directory exists, writing label")

    # Write the label atomically (temp file + rename to avoid importer reading truncated file)
    label_file = full_path / "label.txt"
    try:
        tmp = full_path / ".label.txt.tmp"
        tmp.write_text(message.content.strip())
        tmp.rename(label_file)
        await message.add_reaction("✅")
        log(f"📝 Wrote label to {label_file}: {message.content.strip()}")
    except Exception as e:
        await message.add_reaction("❌")
        await message.reply(f"Failed to write label: {e}")
        log(f"ERROR: {e}")
        return

    # Try to rename folder and update Discord embed (only if processing is complete)
    new_path = maybe_rename_folder(full_path, message.content.strip())
    if new_path:
        await update_discord_embed(new_path)
        await message.add_reaction("📁")
    elif not new_path and DISCORD_WEBHOOK_URL:
        # Processing may still be in progress — importer will handle rename + embed update
        if DEBUG:
            log("Folder not renamed (processing may be in progress or already correct name)")

client.run(BOT_TOKEN)
