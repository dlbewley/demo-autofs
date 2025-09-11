# NFS Server in OpenShift Virtualization Linux VM

* Add any required changes to [userData script](base/scripts/userData), but do not commit the changes to git.

* Upload this to 1Password or another ClusterSecretStore.

```bash
vault=eso
vm=nfs
op item create \
    --vault "$vault" \
    --category login \
    --title "demo autofs $vm" \
    --url "https://github.com/dlbewley/demo-autofs/tree/main/${vm}/base/scripts" \
    --tags demo=autofs \
    "[file]=${vm}/base/scripts/userData"
```

## Network Overlays

This NFS server supports two network overlay configurations:

### Localnet Overlay ([overlays/localnet](overlays/localnet))
- **Purpose**: Uses localnet VLAN 1924 with DHCP
- **Network**: Connects to `localnet-1924-dhcp` network
- **Use Case**: When the NFS server needs to be on the lab network (192.168.4.0/24) with other cluster and datacenter based workloads

### L2 Overlay ([overlays/l2](overlays/l2)) WIP
- **Purpose**: Uses L2 primary UDN overlay network for infrastructure connectivity
- **Network**: Connects to the `infra` L2 P-UDN overlay network

## Deployment Options

* Deploy with localnet overlay:
```bash
oc apply -k nfs/overlays/localnet
# or
oc apply -k argo-apps/nfs
```

* Deploy with L2 overlay:
```bash
# WIP do not use
oc apply -k nfs/overlays/l2
```
