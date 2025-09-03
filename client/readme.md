# NFS Client in OpenShift Virtualization Linux VM

* Add any required changes to [userData script](base/scripts/userData), but do not commit the changes to git.

* Upload this to 1Password or another ClusterSecretStore.

```bash
vault=eso
vm=client
op item create \
    --vault "$vault" \
    --category login \
    --title "demo autofs $vm" \
    --url "https://github.com/dlbewley/demo-autofs/tree/main/${vm}/base/scripts" \
    --tags demo=autofs \
    "[file]=${vm}/base/scripts/userData"
```

* Deploy the VM

```bash
oc apply -k client/base
# or
oc apply -k argo-apps/client
```
