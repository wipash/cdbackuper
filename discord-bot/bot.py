#!/usr/bin/env python3
import discord
import os
import re
from pathlib import Path

DATA_ROOT = os.getenv("DATA_ROOT", "/data")
BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")
DEBUG = os.getenv("DEBUG", "false").lower() in ("true", "1", "yes")

def log(msg):
    print(f"[DEBUG] {msg}" if DEBUG else msg)

if not BOT_TOKEN:
    print("ERROR: DISCORD_BOT_TOKEN not set")
    exit(1)

intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)

@client.event
async def on_ready():
    log(f"✅ Bot ready as {client.user}")
    log(f"DATA_ROOT: {DATA_ROOT}")
    log(f"DEBUG mode: {DEBUG}")

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

    # Write the label
    label_file = full_path / "label.txt"
    try:
        label_file.write_text(message.content.strip())
        await message.add_reaction("✅")
        log(f"📝 Wrote label to {label_file}: {message.content.strip()}")
    except Exception as e:
        await message.add_reaction("❌")
        await message.reply(f"Failed to write label: {e}")
        log(f"ERROR: {e}")

client.run(BOT_TOKEN)
