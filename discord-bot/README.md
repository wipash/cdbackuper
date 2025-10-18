# CD Label Bot

Simple Discord bot that listens for replies to CD archival notifications and writes user-provided labels to the NFS archive.

## How It Works

1. CD finishes processing → notification sent to Discord
2. You reply to the notification with the disc label (e.g., "Northern Territory 2003")
3. Bot extracts the path from the notification and writes your reply to `label.txt`
4. Bot reacts with ✅ to confirm

## Setup

### 1. Create Discord Bot

1. Go to https://discord.com/developers/applications
2. Create new application → "CD Label Bot"
3. Go to Bot tab → Reset Token → Copy token
4. Enable "Message Content Intent" under Privileged Gateway Intents
5. Go to OAuth2 → URL Generator:
   - Scopes: `bot`
   - Bot Permissions: `Send Messages`, `Read Message History`, `Add Reactions`
6. Copy the generated URL and invite bot to your server

### 2. Add Bot Token to Kubernetes Secret

```bash
kubectl -n cd-import create secret generic cd-archiver-config \
  --from-literal=discord-webhook-url='https://discord.com/api/webhooks/...' \
  --from-literal=discord-bot-token='YOUR_BOT_TOKEN_HERE' \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 3. Build and Deploy

```bash
# Build and push image
cd discord-bot
podman build -t ghcr.io/wipash/cd-label-bot .
podman push ghcr.io/wipash/cd-label-bot:latest

# Deploy to Kubernetes
kubectl apply -f deployment.yaml

# Check logs
kubectl -n cd-import logs -f deployment/cd-label-bot
```

## Testing

Send a test message in Discord that looks like a CD notification:
```
**Path:** test-abc-123_MY_DISC
```

Reply to it with a label, bot should react with ✅.

## Architecture

- **Python 3.11** with discord.py
- **NFS mount**: Same `/data` volume as the DaemonSet
- **Single replica**: Only need one bot instance
- **Message intents**: Required to read message content
