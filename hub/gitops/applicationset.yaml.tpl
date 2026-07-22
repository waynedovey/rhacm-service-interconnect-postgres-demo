apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: si-demo
  namespace: openshift-gitops
spec:
  generators:
    - clusterDecisionResource:
        configMapRef: ocm-placement-generator
        labelSelector:
          matchLabels:
            cluster.open-cluster-management.io/placement: si-demo-clusters
        requeueAfterSeconds: 30
  template:
    metadata:
      name: '{{name}}-si-demo'
      labels:
        app.kubernetes.io/part-of: rhacm-service-interconnect-demo
        apps.open-cluster-management.io/reconcile-rate: medium
    spec:
      project: si-demo
      destination:
        name: '{{name}}'
        namespace: default
      source:
        repoURL: __REPO_URL__
        targetRevision: __REVISION__
        path: 'clusters/{{name}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
          allowEmpty: false
        syncOptions:
          - CreateNamespace=true
          - ApplyOutOfSyncOnly=true
          - RespectIgnoreDifferences=true
        retry:
          limit: 20
          backoff:
            duration: 10s
            factor: 2
            maxDuration: 3m
