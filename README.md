# cdbackuper
A little system running in Kubernetes (although it doesn't really need to), that:
- Watches for inserted CDs
- Extracts their contents using `ddrescue`
- Dumps files from the iso
- Saves everything to a NAS
- Sends a Discord notification when done
- **Automatically retries failed discs** on different hardware by resuming from ddrescue mapfiles

The main reason for this is to archive a large collection of CDs containing photos and other media from my grandparents, which will not only preserve the data but also allow easier access to it in the future.

When a disc fails to fully recover, simply re-insert it on a different node/drive - the system automatically detects duplicates by UUID and resumes recovery from where it left off.

### Edit and test the script
The main logic is in `cd-importer.sh`. After editing, regenerate the deployment manifest:
```bash
shellcheck cd-importer.sh
./build-deploy.sh
```

### Build container image
```bash
podman build -t ghcr.io/wipash/cdbackuper .
podman login ghcr.io
podman push ghcr.io/wipash/cdbackuper:latest
```

### Create secret for Discord
```bash
kubectl create secret generic cd-archiver-config \
  --from-literal=discord-webhook-url='https://discord.com/api/webhooks/webhookid/webhooktoken' \
  -n cd-import
```

### Deploy
```bash
./build-deploy.sh  # Generate deploy.yaml from template
kubectl apply -f deploy.yaml
```

### Update
```bash
kubectl -n cd-import rollout restart daemonset/cd-importer
```

### Monitor
```bash
kubectl -n cd-import logs -f -l app=cd-importer --prefix=true
```
