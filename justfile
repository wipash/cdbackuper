# CD Archiver build and deploy recipes

registry := "ghcr.io/wipash"

# Ensure we're logged in to ghcr.io
[private]
login:
    @grep -q ghcr.io ~/.docker/config.json 2>/dev/null || docker login ghcr.io --username wipash

# Build and push the discord label bot image
discord: login
    docker build -t {{registry}}/cd-label-bot discord-bot/
    docker push {{registry}}/cd-label-bot:latest

# Build and push the cdbackuper image
cdbackuper: login
    docker build -t {{registry}}/cdbackuper .
    docker push {{registry}}/cdbackuper:latest

# Generate deploy.yaml from template
builddeploy:
    ./build-deploy.sh

# Deploy everything to Kubernetes and restart to pick up new images
deploy: builddeploy
    kubectl apply -f deploy.yaml
    kubectl apply -f discord-bot/deployment.yaml
    kubectl -n cd-import rollout restart daemonset/cd-importer
    kubectl -n cd-import rollout restart deployment/cd-label-bot
