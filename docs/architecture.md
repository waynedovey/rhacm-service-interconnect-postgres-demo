# Architecture

## Control plane

The RHACM hub owns:

- Operator lifecycle policies
- Managed-cluster placement decisions
- OpenShift GitOps
- The `GitOpsCluster` registration
- The Argo CD `ApplicationSet`

The hub GitOps controller uses the RHACM push model to apply resources directly to both managed clusters.

## Managed clusters

### cluster-pwv6d

- Logical Site A
- Service Interconnect listening site
- Service Interconnect `AccessGrant`
- CloudNativePG primary `bookinfo-db`
- Bookinfo
- Local demo Vault and External Secrets

### cluster-7b6lh

- Logical Site B
- Service Interconnect connecting site
- External Secrets-managed access-token data
- CloudNativePG replica `bookinfo-db-replica`
- Bookinfo
- Local demo Vault and External Secrets

## Network flow

```text
cluster-7b6lh PostgreSQL replica
        |
        | postgres-site-a:5432
        v
Service Interconnect Listener
        |
        | mTLS application network
        v
Service Interconnect Connector
        |
        v
cluster-pwv6d bookinfo-db-rw:5432
```

## Application flow

Both Bookinfo `productpage` pods have a `db-heartbeat` sidecar. The sidecar uses the same multi-host libpq connection string and writes a row every 15 seconds.

The Site B sidecar normally reaches the Site A primary through Service Interconnect. Site A uses the local primary alias first.

## Secret flow

```text
bootstrap.sh
   |
   +--> local demo Vault on cluster-pwv6d
   |      +--> Bookinfo application credentials
   |
   +--> local demo Vault on cluster-7b6lh
          +--> Bookinfo application credentials
          +--> CloudNativePG replication TLS material
          +--> Service Interconnect token data
                    |
                    v
             External Secrets
                    |
                    v
             Kubernetes Secrets
```
