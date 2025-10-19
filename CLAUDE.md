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
   CD inserted → Device detection → Duplicate check → Lock acquired → Background job spawned →
   Metadata dump → ddrescue (fast + retry passes, resumes from mapfile if duplicate) →
   ISO validation → File extraction → Discord notification → Disc ejection → Lock released

   User replies with label → Bot writes to label.txt
   ```

   **Duplicate Detection & Retry**: When a disc is re-inserted, the system detects it by UUID and automatically:
   - Resumes ddrescue from the existing mapfile (retrying only failed sectors)
   - Backs up previous ddrescue output with timestamp
   - Tracks which nodes have attempted recovery in `status.json`
   - Sends Discord notification indicating retry attempt and previous nodes

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
├── blkid.txt                           # Device metadata
├── isoinfo.txt                         # ISO filesystem info
├── ddrescue.mapfile                    # ddrescue recovery map (persistent across retries)
├── ddrescue-output.txt                 # Full ddrescue stdout/stderr (current attempt)
├── ddrescue-output.txt.backup-YYYYMMDD-HHMMSS  # Previous attempt backups (retry only)
├── status.json                         # Processing status, stats, and retry history
├── label.txt                           # User-provided label (created by Discord bot on reply)
├── disc.iso                            # Raw ISO image (deleted if extraction succeeds)
└── files/                              # Extracted files from ISO
```

**Retry Workflow**: When the same disc is re-inserted (detected by UUID):
- The existing `ddrescue.mapfile` is reused to resume from where the last attempt left off
- Previous `ddrescue-output.txt` is backed up with a timestamp
- `status.json` tracks `is_retry: true` and lists all nodes that have attempted recovery in `retry_nodes`
- Different hardware may successfully read sectors that previously failed

## Troubleshooting

### Common Issues

1. **Pod stuck in init**: Check NFS mount accessibility from node
2. **Permission denied on /data**: Verify fsGroup matches NFS server GID (65537)
3. **Disc not detected**: Check udev mounts and device permissions
4. **ISO extraction fails**: Check `isoinfo.txt` for corruption indicators
5. **Timeout killing processes**: Increase `TIMEOUT` env var for slow/damaged discs

### Retrying Failed Discs

If a disc fails to fully recover (partial recovery with read errors):

1. **Check the failure details**:
   ```bash
   # View the disc's status
   cat /data/{UUID}_{LABEL}/status.json | jq '.'

   # Check which nodes attempted recovery
   cat /data/{UUID}_{LABEL}/status.json | jq '.retry_nodes'
   ```

2. **Try a different node/drive**: Simply re-insert the same disc on a different node in your cluster. The system will:
   - Automatically detect it's the same disc (by UUID)
   - Resume ddrescue from the existing mapfile
   - Only attempt to read the sectors that previously failed
   - Send a Discord notification showing it's a retry attempt

3. **Monitor retry progress**:
   ```bash
   # Watch logs for the retry attempt
   kubectl -n cd-import logs -f -l app=cd-importer --prefix=true | grep "DUPLICATE DETECTED"

   # Check ddrescue progress during retry
   tail -f /data/{UUID}_{LABEL}/ddrescue-output.txt
   ```

4. **Review retry history**: Previous ddrescue outputs are preserved as backups:
   ```bash
   ls -la /data/{UUID}_{LABEL}/ddrescue-output.txt.backup-*
   ```

**Note**: Duplicate detection relies on the disc having a filesystem UUID. Discs without UUIDs (audio CDs, blank discs) will create new directories on each insertion and won't trigger retry logic.

### Node Affinity

The DaemonSet explicitly excludes node `hp1` due to CD drive issues. Update the `nodeAffinity` section in `deploy.yaml` to exclude additional problematic nodes.
