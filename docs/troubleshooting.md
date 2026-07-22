# Troubleshooting

## Operator policies are NonCompliant

```bash
oc get policy -n si-demo-policies
oc describe policy install-service-interconnect -n si-demo-policies
oc describe policy install-external-secrets -n si-demo-policies
oc describe policy install-cloudnative-pg -n si-demo-policies
```

Check the replicated policy in each managed-cluster namespace:

```bash
oc get policy -n cluster-pwv6d
oc get policy -n cluster-7b6lh
```

## CloudNativePG package is unavailable

Check the community catalog:

```bash
oc --kubeconfig .work/kubeconfigs/cluster-pwv6d.kubeconfig \
  get packagemanifest cloudnative-pg -n openshift-marketplace -o yaml
```

If the community catalog is disabled, enable it or change the Subscription source in:

```text
hub/policies/40-policy-cloudnative-pg.yaml
```

## ApplicationSet does not create Applications

```bash
oc get placementdecision -n openshift-gitops
oc get gitopscluster si-demo -n openshift-gitops -o yaml
oc get secret -n openshift-gitops \
  -l argocd.argoproj.io/secret-type=cluster
oc describe applicationset si-demo -n openshift-gitops
```

## Vault pod does not start

The demo uses the `anyuid` SCC through a namespace RoleBinding.

```bash
oc --kubeconfig .work/kubeconfigs/cluster-pwv6d.kubeconfig \
  describe pod -n vault-demo -l app.kubernetes.io/name=vault-demo
```

Confirm the bootstrap secret exists:

```bash
oc --kubeconfig .work/kubeconfigs/cluster-pwv6d.kubeconfig \
  get secret vault-root-token vault-auth -n vault-demo
```

## ExternalSecret is not Ready

```bash
oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  describe clustersecretstore demo-vault

oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  describe externalsecret -n bookinfo
```

Confirm Vault has the values:

```bash
POD=$(oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  get pod -n vault-demo -l app.kubernetes.io/name=vault-demo \
  -o jsonpath='{.items[0].metadata.name}')

source .work/demo.env

oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  exec -n vault-demo "${POD}" -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN}" \
  vault kv list secret
```

## Service Interconnect link is not Ready

```bash
oc --kubeconfig .work/kubeconfigs/cluster-pwv6d.kubeconfig \
  get site,accessgrant -n bookinfo -o wide

oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  get site,accesstoken,link -n bookinfo -o wide

oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  logs job/service-interconnect-link-bootstrap -n bookinfo
```

A token expires. Delete the Site B AccessToken and link job, then rerun `bootstrap.sh` to issue a fresh token:

```bash
oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  delete accesstoken token-to-cluster-pwv6d -n bookinfo --ignore-not-found

oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  delete job service-interconnect-link-bootstrap -n bookinfo --ignore-not-found
```

## Replica cannot bootstrap

Check the replica cluster and pods:

```bash
oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  describe cluster bookinfo-db-replica -n bookinfo

oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  logs -n bookinfo -l cnpg.io/cluster=bookinfo-db-replica --all-containers
```

Check the remote PostgreSQL endpoint from the Site B Bookinfo heartbeat container:

```bash
POD=$(oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  get pod -n bookinfo -l app=productpage \
  -o jsonpath='{.items[0].metadata.name}')

oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  exec -n bookinfo "${POD}" -c db-heartbeat -- \
  bash -c 'PGPASSWORD="${POSTGRES_PASSWORD}" psql \
    "host=postgres-site-a port=5432 dbname=postgres user=streaming_replica sslmode=verify-ca connect_timeout=10" \
    -c "select now();"'
```

## Bookinfo heartbeat is not writing

```bash
oc --kubeconfig .work/kubeconfigs/cluster-pwv6d.kubeconfig \
  logs deployment/productpage -n bookinfo -c db-heartbeat --tail=100

oc --kubeconfig .work/kubeconfigs/cluster-7b6lh.kubeconfig \
  logs deployment/productpage -n bookinfo -c db-heartbeat --tail=100
```
