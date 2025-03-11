# Bootstraping Manual

## Cluster init

Run kubeadm init with the kubeadmconfig of this repo.

```bash
sudo kubeadm init --config bootstrap/kubernetes/kubeadm.yaml --upload-certs
```

You need to also label the nodes:

```yaml
topology.kubernetes.io/region: proxmox-alv
topology.kubernetes.io/zone: proxmox-alv
```

## Bootstrap initial secrets

Fill the secrets.yaml template in bootstrap/kubernetes/secrets.tmpl.yaml

then run:

```bash
kubectl apply -f bootstrap/kubernetes/secrets.yaml
```

## Cilium init

```bash
cd bootstrap/cilium
helm repo add cilium https://helm.cilium.io/
helm repo update
API_SERVER_IP=10.250.0.3
API_SERVER_PORT=6443
helm template cilium cilium/cilium --version 1.16.5 \
    --namespace kube-system \
    --set l2announcements.enabled=true \
    --set socketLB.hostNamespaceOnly=true \
    --set kubeProxyReplacement=true \
    --set envoy.enabled=false \
    --set k8sServiceHost=${API_SERVER_IP} \
    --set k8sServicePort=${API_SERVER_PORT} \
    --set operator.updateStrategy.type=Recreate \
    --set operator.updateStrategy.rollingUpdate=null \
    --set operator.replicas=1 \
    --set cni.exclusive=false \
    --set ipam.operator.clusterPoolIPv4PodCIDRList=10.244.0.0/16 \
    --set ipam.operator.clusterPoolIPv4MaskSize=23 > bundle.yaml | kubectl apply -f -
```

Don't stress, fluxcd will take control post-bootstrap later on.

## Fluxcd (GitOps)

Deploy fluxcd and gitops resources in the cluster

```bash
kustomize build bootstrap/fluxcd/upstream | kubectl apply -f -
kustomize build bootstrap/fluxcd/setup | kubectl apply -f -
kustomize build bootstrap/fluxcd/ | kubectl apply -f -
```

## Configure loadbalancer ippool

```bash
kubectl apply -f bootstrap/cilium/l2LBConfig.yaml
```

## Vault init

Port forward to the vault instance

Fill the secrets file tmpl and apply the terraform vault manifests.

```bash
cd bootstrap/tf/vault
terraform init
terraform apply
```

Everything should start itself from here.

## Enable auto vault unsealer-operator

Fill this secret and apply it.

```yaml
apiVersion: v1
stringData:
  key1: <xxx>
  key2: <xxx>
kind: Secret
metadata:
  name: thresholdkeys
  namespace: vault-unsealer-operator-system
type: Opaque
```

## Provision a clusters

Apply the following template to the mgmt cluster to create a cluster:

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: bealv-test
  namespace: capi-system
  labels:
    cert-manager: 'true'
    cni: cilium
    external-dns: 'true'
    external-secret: 'true'
    external-snapshotter: 'true'
    fluxcd: 'true'
    ingress-controller: 'true'
    monitoring: 'true'
    proxmox-csi: 'true'
    velero: 'true'
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
        - 172.16.0.0/16
    serviceDomain: bealv-test.local
    services:
      cidrBlocks:
        - 172.17.0.0/16
  topology:
    variables:
      - name: ipv4Config
        value:
          addresses:
            - 10.250.2.0-10.250.2.10
          gateway: 10.250.0.1
          prefix: 16
      - name: dnsServers
        value:
          - 10.250.0.1
      - name: templateID
        value: 102
    class: kamaji-proxmox
    version: v1.31.4
    controlPlane:
      replicas: 1
    workers:
      machineDeployments:
        - class: default-worker
          name: worker
          replicas: 1
```
