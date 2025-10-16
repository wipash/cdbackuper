# cdbackuper

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
kubectl apply -f deploy.yaml
```

### Update
```bash
kubectl -n cd-import rollout restart daemonset/cd-importer
```
