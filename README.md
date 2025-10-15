# cdbackuper

### Deploy
kubectl apply -f deploy.yaml

### Update
kubectl -n cd-import rollout restart daemonset/cd-importer
