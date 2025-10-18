# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

cdbackuper is a Kubernetes-based CD archival system that automatically detects inserted CDs, extracts their contents using ddrescue, and saves everything to a NAS. It's designed to preserve a large collection of CDs containing photos and other media, with Discord notifications for completion status.

## Architecture

### Deployment Model
The system runs as a **Kubernetes DaemonSet** in the `cd-import` namespace. This ensures one pod runs on each node in the cluster that has CD/DVD drives. However, node affinity rules prevent scheduling on problematic nodes (currently `hp1`).

### Core Components

1. **Script-based Processing** (`cd-importer.sh`):
   - Embedded in a ConfigMap and mounted into the container at runtime
   - The container itself just runs `sleep infinity` - the script is the entrypoint
   - Main loop polls CD devices (default `/dev/sr*`) every 5 seconds
   - Uses atomic directory-based locks (`mkdir`) to prevent race conditions when multiple discs are detected
   - Processes each disc in a background job, tracking active PIDs to prevent zombie processes

2. **Discord Label Bot** (`discord-bot/`):
   - Python bot that listens for replies to CD archival notifications
   - Allows you to add human-readable labels to discs after processing completes
   - Writes labels to `label.txt` in each disc's output directory
   - See `discord-bot/README.md` for setup instructions

3. **Data Flow**:
   ```
   CD inserted → Device detection → Lock acquired → Background job spawned →
   Metadata dump → ddrescue (fast + retry passes) → ISO validation →
   File extraction → Discord notification → Disc ejection → Lock released

   User replies with label → Bot writes to label.txt
   ```

4. **Storage Architecture**:
   - **NFS PersistentVolume** mounted at `/data` (1Ti, ReadWriteMany)
   - NFS server: `172.20.0.1:/volume1/Backup/Maurice/cd-archive`
   - Output directories named: `{UUID}_{LABEL}` or `{TIMESTAMP}_{LABEL}`
   - ISO files are auto-deleted after successful file extraction (configurable via `DELETE_ISO_ON_SUCCESS`)

5. **Concurrency & Safety**:
   - Each device gets a lockfile in `/var/run/cd-import/`
   - Timeout guard (default 7200s) kills hung ddrescue processes
   - Mount point cleanup via traps (EXIT, INT, TERM)
   - NFS mount validation at startup prevents silent failures

### Key Design Decisions

- **Privileged Containers**: Required for raw device access and mounting ISOs
- **Host PID/IPC**: Necessary for udev device detection and drive control
- **fsGroup 65537**: Matches NFS server GID for proper file permissions
- **Two-Pass ddrescue**: Fast pass (`-n`) followed by retry passes (`-r`) maximizes recovery while minimizing time on good discs
- **ISO Integrity Check**: Uses `isoinfo -d` before mounting to avoid corrupt ISO extraction attempts

## Common Commands

### Working with the Script

The main logic lives in `cd-importer.sh`. After editing it, regenerate `deploy.yaml`:

```bash
# Regenerate deploy.yaml from template
./build-deploy.sh

# Run shellcheck on the script
shellcheck cd-importer.sh
```

**Note**: `deploy.yaml` is generated from `deploy.yaml.template` and should not be edited directly. The build script injects `cd-importer.sh` into the ConfigMap section of the template.

### Building and Deploying

```bash
# Build and push container image
podman build -t ghcr.io/wipash/cdbackuper .
podman login ghcr.io
podman push ghcr.io/wipash/cdbackuper:latest

# Generate deploy.yaml and deploy to Kubernetes
./build-deploy.sh
kubectl apply -f deploy.yaml

# Restart DaemonSet after image update
kubectl -n cd-import rollout restart daemonset/cd-importer
```

### Monitoring and Debugging

```bash
# Watch logs from all pods (with pod name prefix)
kubectl -n cd-import logs -f -l app=cd-importer --prefix=true

# Check specific pod logs
kubectl -n cd-import get pods
kubectl -n cd-import logs -f <pod-name>

# Verify NFS mount in running pod
kubectl -n cd-import exec -it <pod-name> -- mountpoint /data

# Check active disc processing jobs
kubectl -n cd-import exec -it <pod-name> -- ps aux | grep ddrescue
```

### Configuration

```bash
# Create Discord secrets (webhook required for notifications, bot token optional for labels)
kubectl create secret generic cd-archiver-config \
  --from-literal=discord-webhook-url='https://discord.com/api/webhooks/ID/TOKEN' \
  --from-literal=discord-bot-token='YOUR_BOT_TOKEN' \
  -n cd-import

# Verify secret exists
kubectl -n cd-import get secret cd-archiver-config

# Deploy label bot (optional - see discord-bot/README.md for setup)
cd discord-bot
podman build -t ghcr.io/wipash/cd-label-bot .
podman push ghcr.io/wipash/cd-label-bot:latest
kubectl apply -f deployment.yaml
```

## Environment Variables

Configured in `deploy.yaml` under container env section:

- `DATA_ROOT`: Mount path for NFS storage (default: `/data`)
- `DEVICE_GLOB`: Pattern for CD devices to monitor (default: `/dev/sr*`)
- `RETRIES`: Number of ddrescue retry passes after fast pass (default: `2`)
- `TIMEOUT`: Max seconds per disc before killing ddrescue (default: `7200`)
- `EXTRACT_FILES`: Whether to extract files from ISO (default: `true`)
- `DELETE_ISO_ON_SUCCESS`: Auto-delete ISO after successful extraction (default: `true`)
- `POLL_SECS`: Device polling interval (default: `5`)
- `DISCORD_WEBHOOK_URL`: Discord webhook for notifications (from secret, optional)
- `NODE_NAME`: Injected automatically from Kubernetes fieldRef

## Output Directory Structure

Each processed disc creates:
```
/data/{UUID}_{LABEL}/
├── blkid.txt              # Device metadata
├── isoinfo.txt            # ISO filesystem info
├── ddrescue.mapfile       # ddrescue recovery map
├── ddrescue-output.txt    # Full ddrescue stdout/stderr
├── status.json            # Processing status and stats
├── label.txt              # User-provided label (created by Discord bot on reply)
├── disc.iso               # Raw ISO image (deleted if extraction succeeds)
└── files/                 # Extracted files from ISO
```

## Troubleshooting

### Common Issues

1. **Pod stuck in init**: Check NFS mount accessibility from node
2. **Permission denied on /data**: Verify fsGroup matches NFS server GID (65537)
3. **Disc not detected**: Check udev mounts and device permissions
4. **ISO extraction fails**: Check `isoinfo.txt` for corruption indicators
5. **Timeout killing processes**: Increase `TIMEOUT` env var for slow/damaged discs

### Node Affinity

The DaemonSet explicitly excludes node `hp1` due to CD drive issues. Update the `nodeAffinity` section in `deploy.yaml` to exclude additional problematic nodes.
