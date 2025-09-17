# Deploying VMs using ArgoCD

Overview of deploying VMs as applications using ArgoCD. The same can be accomplished just using kustomize if desired.

# Argo Apps

The following ArgoCD applications are defined:

* [demo-autofs App of Apps](demo-autofs/kustomization.yaml) - Deploys all of the following:
  * [demo-autofs-networking](networking/application.yaml) - Sets up required networking configuration _(sync wave -1)_
  * [demo-autofs-ldap](ldap/application.yaml) - Deploys LDAP server VM _(sync wave 0)_
  * [demo-autofs-nfs](nfs/application.yaml) - Deploys NFS server VM _(sync wave 3)_
  * [demo-autofs-client](client/application.yaml) - Deploys client VM _(sync wave 4)_

Each [VirtualMachine](../client/base/virtualmachine.yaml) resource within each app has a sync wave annotation of 1 with the intention of it following the ExternalSecret reconciliation.

## Deploying Everything as an App of Apps

This will deploy an app of apps enabling the deployment of the entire demo through a single entry point.

```bash
oc apply -k argo-apps/demo-autofs
```

![ArgoCD App of Apps](../img/argo-app-of-apps-demo-autofs.png)

## Deploying Each App Individually

This will deploy each app individually.

```bash
oc apply -k argo-apps/networking
oc apply -k argo-apps/ldap
oc apply -k argo-apps/nfs
oc apply -k argo-apps/client
```

## Deployed Applications

![Networking ArgoCD App](../img/argo-app-demo-autofs-network.png)
![LDAP VM ArgoCD App](../img/argo-app-demo-autofs-ldap.png)
![NFS VM ArgoCD App](../img/argo-app-demo-autofs-nfs.png)
![CLient VM ArgoCD App](../img/argo-app-demo-autofs-client.png)

Here is a view of the LDAP application from RHACM.

![LDAP VM ArgoCD App in ACM](../img/acm-app-demo-autofs-ldap.png)

> [!IMPORTANT]
> The default ArgoCD resources may be too low. I've seen the argo controller go into crashloop backoff following an OOMKill event.
> https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.17/html/managing_resource_use/configuring-resource-quota

* Use this patch to increase the memory available to the ArgoCD Controller.

```yaml
$ oc get argocd/openshift-gitops -n openshift-gitops -o yaml | yq .spec.controller
processors: {}
resources:
  limits:
    cpu: "2"
    memory: 2Gi
  requests:
    cpu: 250m
    memory: 1Gi
sharding: {}

$ oc patch argocd/openshift-gitops -n openshift-gitops --type='json' \
  -p='[
    {"op": "replace", "path": "/spec/controller/resources/requests/memory", "value":"2Gi"},
    {"op": "replace", "path": "/spec/controller/resources/limits/memory", "value":"4Gi"},
    ]'
```

# Securing Cloud-init User Data

The
[client](../client/base/scripts/userData),
[ldap](../ldap/base/scripts/userData), and
[nfs](../nfs/base/scripts/userData)
userData secrets contain credentials which should not be stored in GitHub.

The application deployment will generate an unused secret with a `-sample` suffix using the value found in git for reference. The actually secret used by cloud-init will be generated from an [externalsecret](../client/base/externalsecret.yaml) resource.

Details on configuring the External Secret Operator are below.

## Installing the External Secrets Operator

Install a version of ESO which supports the 1password-sdk provider. The 1password-connect provider is deprecated provider and the operators in the OpenShift catalog as of 2025-08 are based on ESO 0.10.0.

* Install latest upstream ESO using Helm

```bash
$ helm repo add external-secrets https://charts.external-secrets.io

$ oc new-project external-secrets

$ helm install external-secrets \
   external-secrets/external-secrets \
   -n external-secrets
```

## Configuring 1Password

The External Secrets Operator supports many providers including Hashicorp Vault for example. I am using 1Password for it's ease of setup.

* Create a dedicated vault in 1Password for use by ESO

```bash
$ op vault create eso --icon gears
```

* Create a token to authenticate ESO to 1Password. (90 days was max allowed)

```bash
$ TOKEN=$(
    op service-account create external-secrets-operator \
      --expires-in 90d \
      --vault eso:read_items,write_items \
    )
```

* Place token in a secret allowing ESO to access 1Password

 ```bash
$ oc create secret generic onepassword-connect-token \
  --from-literal=token="$TOKEN" \
  -n external-secrets
```

> [!TIP]
> Test the token to confirm access to the vault items.
> ```bash
>  $ export OP_SERVICE_ACCOUNT_TOKEN=$(oc extract secret/onepassword-connect-token -n external-secrets --keys=token --to=-)
>  $ op item list --vault eso
>  ID                            TITLE                            VAULT            EDITED
>  yzsurcc4oxfjp7qdidonudn3ne    demo autofs ldap                 eso              22 hours ago
>  wretasduq3rkip7wn37njozghi    demo autofs nfs                  eso              22 hours ago
>  euaujb4izjftqineetzaer3x7i    demo autofs client               eso              5 days ago
>  ```

## Configuring the External Secrets Operator

* Create a `ClusterSecretStore`

```yaml
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: 1password-sdk
spec:
  provider:
    onepasswordSDK:
      vault: eso
      auth:
        serviceAccountSecretRef:
          name: onepassword-connect-token
          key: token
          namespace: external-secrets
```

## Write Data 1Password

* Copy and edit the `{client,ldap,nfs}/base/scripts/userData` scripts. Insert the configuration that should not be stored in git. Eg. Red Hat subscription activation keys.

* Store the the updated userData for each VM in 1Password <https://developer.1password.com/docs/cli/item-create/>

```bash
vault=eso
for vm in client ldap nfs; do
  op item create \
    --vault "$vault" \
    --category login \
    --title "demo autofs $vm" \
    --url "https://github.com/dlbewley/demo-autofs/tree/main/${vm}/base/scripts" \
    --tags demo=autofs \
    "userData[file]=${vm}/base/scripts/userData"
done
```

* Update data in 1Password

```bash
vault=eso
for vm in client; do
  op item edit \
    --vault "$vault" \
    --url "https://github.com/dlbewley/demo-autofs/tree/main/${vm}/base/scripts" \
    "demo autofs $vm" \
    "userData[file]=${vm}/base/scripts/userData"
done
```


Here is a view of the 1Password vault.

![../img/1password-vault.png](../img/1password-vault.png)

### Read Data from 1Password

* Create an `{client,ldap,nfs}/base/externalsecret.yaml` for each VM.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cloudinitdisk-client
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: 1password-sdk
  target:
    name: cloudinitdisk-client # this will be the name of the secret
    creationPolicy: Owner
  data:

  - secretKey: "userData" # this will be a field in the secret
    remoteRef:
      key: "demo autofs client/userData"
```

This ExternalSecret will cause a Secret named `cloudinitdisk-client` to be generated by the ESO.

# Cleanup

* Remove everything

```bash
oc delete -k argo-apps/demo-autofs
# or
oc delete application.argoproj.io/demo-autofs -n openshift-gitops
```

The Cluster User Defined Network controller will prevent the deletion of namespaces assocated with [CUDNs](../components/localnet-1924/clusterdefinednetwork.yaml) through namespace selectors. In this case the label we are using is `vlan-1924=""`.

> [!IMPORTANT]
> Remove the label from the namespace to allow the deletion to proceed.
>
> ```bash
> oc label namespace demo-client vlan-1924-
> oc label namespace demo-ldap vlan-1924-
> oc label namespace demo-nfs vlan-1924-
> ```

> [!IMPORTANT]
> If deletion of the parent app fails due to missing child apps, remove the finalizer.
> ```bash
> oc patch application.argoproj.io demo-autofs -n openshift-gitops -p '{"metadata":{"finalizers":null}}' --type=merge
> ```