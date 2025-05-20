# Using CoreOS Image Layering to run automountd

RHEL CoreOS is a container optimized operating system distributed via a container image. Typically one does not install software directly into the host operating system, but instead runs services via containers.

The [RHCOS Image Layering](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/machine_configuration/mco-coreos-layering) feature of OpenShift allows to the ability to install software at the host level in a manner compatible with the automated node lifecycle management performed by OpenShift.

[internal deck](https://docs.google.com/presentation/d/14rIn35xjR8cptqzYwDoFO6IOWIUNkSBZG3K2-5WJKok/edit?slide=id.g547716335e_0_220#slide=id.g547716335e_0_220)


Draft docs:

* https://issues.redhat.com/browse/OSDOCS-13346
* https://87486--ocpdocs-pr.netlify.app/openshift-enterprise/latest/machine_configuration/mco-coreos-layering.html

> [!IMPORTANT]
> On cluster image layering is TP as of 4.18 and anticipated to GA in 4.19.

> [!WARNING]
> Use of image layering will lead to potentially unanticipated reboots when the CA signing cert is rotated and subsequently removed. This occurs at 80% and 100% of the cert lifetime.
> This can be obviated through a coordinated pause of the machineconfig pool.


Note the following limitations when working with the on-cluster layering feature:

* If you scale up a machine set that uses a custom layered image, the nodes reboot two times. The first, when the node is initially created with the base image and a second time when the custom layered image is applied.
* Node disruption policies are not supported on nodes with a custom layered image. As a result the following configuration changes cause a node reboot:
    * Modifying the configuration files in the /var or /etc directory
    * Adding or modifying a systemd service
    * Changing SSH keys
    * Removing mirroring rules from ICSP, ITMS, and IDMS objects
    * Changing the trusted CA, by updating the user-ca-bundle configmap in the openshift-config namespace

## Overview 

To apply a custom layered image to your cluster by using the on-cluster build process, make a MachineOSConfig custom resource (CR) that specifies the following parameters:

the Containerfile to build
the machine config pool to associate the build
where the final image should be pushed and pulled from
the push and pull secrets to use

* One MachineOSConfig resource per machine config pool

## Prerequisites

### OpenShift 4.19

* Testing on 4.18 with TP feature enabled was not successful.
* Tested using OpenShift 4.19rc2 on 2025-05-20

### Image Registry to hold layered image

> [!NOTE]
> Using the on-cluster image registry.
> Skip if using an external registry.

* Identify a registry or [enable the on-cluster registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/registry/setting-up-and-configuring-the-registry#configuring-registry-storage-baremetal)

* Create a PVC on non-default SC

```bash
$ cat <<EOF | oc create -f -
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: image-registry-storage-cephfs
  namespace: openshift-image-registry
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
  storageClassName: ocs-storagecluster-cephfs
  volumeMode: Filesystem
EOF
```

* Enable the on cluster registry using above PVC. 
Optionally [expose the registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/registry/securing-exposing-registry#securing-exposing-registry) for testing.

```bash
# Enable registry - if none exists outside cluster
$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"managementState":"Managed"}}'

$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"storage":{"pvc":{"claim":"image-registry-storage-cephfs"}}}}'

# account for pvc
$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"rolloutStrategy":"Recreate"}}'

# Expose registry
$ oc patch configs.imageregistry.operator.openshift.io/cluster \
    --patch '{"spec":{"defaultRoute":true}}' --type=merge
```

### Pull and Push Secrets

Create a pull-secret with the ability to push to the cluster registry in the `openshift-machine-config-operator` namespace. 

* Create a 2 year duration token per this KCS https://access.redhat.com/solutions/7025261

```bash
export REGISTRY=image-registry.openshift-image-registry.svc:5000
export REGISTRY_USER=builder
export REGISTRY_NAMESPACE=openshift-machine-config-operator
export TOKEN=$(oc create token $REGISTRY_USER -n $REGISTRY_NAMESPACE --duration=$((720*24))h)
```

* Use this token to create a secret named `push-secret`.

```bash
oc create secret docker-registry push-secret \
  -n openshift-machine-config-operator \
  --docker-server=$REGISTRY \
  --docker-username=$REGISTRY_USER \
  --docker-password=$TOKEN
```

> [!NOTE]
> Verify the expiration on the token just created:
> `oc extract secret/push-secret -n openshift-machine-config-operator --to=- | jq -r '.auths."image-registry.openshift-image-registry.svc:5000".auth' | base64 -d | cut -d. -f2 | base64 -d`
> 
> {"aud":["https://kubernetes.default.svc"],"exp":1809913549,"iat":1747705549,"iss":"https://kubernetes.default.svc","jti":"37ec3a2e-bdb1-4897-bc6d-c2d433b4f69f","kubernetes.io":{"namespace":"openshift-machine-config-operator","serviceaccount":{"name":"builder","uid":"7f114eb8-da6b-4be1-8bc4-6c9e9119a252"}},"nbf":1747705549,"sub":"system:serviceaccount:openshift-machine-config-operator:builder"}%
> `date -r 1809913549`
> Sun May  9 21:45:49 EDT 2027

* Combine the global pull secret and the just created push secret. Refer to this secret in the `MachineOSConfig.spec.baseImagePullSecret`

```bash
oc extract secret/pull-secret -n openshift-config --to=- > pull-secret.json

jq -s '.[0] * .[1]' pull-secret.json push-secret.json > pull-and-push-secret.json

oc create secret generic pull-and-push-secret \
  -n openshift-machine-config-operator \
  --from-file=.dockerconfigjson=pull-and-push-secret.json \
  --type=kubernetes.io/dockerconfigjson
```

* Confirm pull secret references in  [machineosconfig.yaml](machineosconfig.yaml) and create it. This machineconfig is associated with the just created `worker-automount` machineconfig pool.

```bash
cat machineosconfig.yaml | yq '.spec | with_entries(select(.key | contains("Secret")))'

baseImagePullSecret:
  name: pull-and-push-secret
renderedImagePushSecret:
  name: push-secret
```

## Build Configs and Layered Image

* Create [worker-test machineconfigpool](machineconfigpool.yaml) to use for initial testing of the image build. Ensure the MCP is initially **paused**.

```bash
oc create -f machineconfigpool.yaml

oc get mcp
NAME               CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1   True      False      False      3              3                   3                     0                      9h
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718   True      False      False      6              6                   6                     0                      9h
worker-automount                                                                                                                                                                      2s
```

> [!NOTE]
> **Entitlements**
>
> Entitlement to download RPMs are enabled by an automatic copy of the `etc-pki-entitlement` secret from the `openshift-config-managed` namespace into the openshift-machine-config-operator namespace.

* Create the MachineOSConfig

```bash
oc create -f machineosconfig.yaml
machineosconfig.machineconfiguration.openshift.io/worker-automount created

# confirm the entitlement secret was copied from openshift-config-managed
oc get secrets |grep entitle
etc-pki-entitlement-worker-automount                      Opaque                                2      49s
```

* A Job in the openshift-machine-config-operator namespace defined by the machineosconfig will begin a machineosbuild

```bash
oc get jobs -n openshift-machine-config-operator
NAME                                                      STATUS    COMPLETIONS   DURATION   AGE
build-worker-automount-641629bea6074d48da5d021cf5176b0b   Running   0/1           12m        12m

oc get machineosbuild
NAME                                                PREPARED   BUILDING   SUCCEEDED   INTERRUPTED   FAILED
worker-automount-641629bea6074d48da5d021cf5176b0b   False      True       False       False         False    12m
```

* Pod start up takes a couple of minutes. Then watch the logs and confirm a successful push of the resulting image.

```bash
oc logs -f build-worker-automount-8789b61df9e702d51c6980cc268e85a7-j9vl6 -n openshift-machine-config-operator
... # SUCESS
+ buildah push --storage-driver vfs --authfile=/tmp/final-image-push-creds/config.json --digestfile=/tmp/done/digestfile --cert-dir /var/run/secrets/kubernetes.io/serviceaccount image-registry.openshift-image-registry.svc:5000/
openshift-machine-config-operator/os-image:worker-automount-8789b61df9e702d51c6980cc268e85a7
...
Copying config sha256:0edf94edf55b9bedc2d3b9659188ca8528bd5dc3ed0397c866f7338d47e034b3
Writing manifest to image destination
+ return 0
```

* Create the [machineconfigs](machineconfig.yaml) that configure autofs.

```bash
oc create -f machineconfig.yaml
machineconfig.machineconfiguration.openshift.io/99-worker-automount-sssd-config created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-autofs-service created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-nfs-homedir-setsebool created
```

## Apply Layered Image to Nodes

```bash
oc get clusterversion
NAME      VERSION       AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.19.0-rc.2   True        False         20h     Cluster version is 4.19.0-rc.2

oc get nodes
NAME                       STATUS   ROLES                  AGE   VERSION
hub-v57jl-cnv-8swxv        Ready    worker                 12h   v1.32.4
hub-v57jl-master-0         Ready    control-plane,master   21h   v1.32.4
hub-v57jl-master-1         Ready    control-plane,master   21h   v1.32.4
hub-v57jl-master-2         Ready    control-plane,master   21h   v1.32.4
hub-v57jl-store-1-wqqb7    Ready    infra,worker           17h   v1.32.4
hub-v57jl-store-2-2hhjk    Ready    infra,worker           17h   v1.32.4
hub-v57jl-store-3-q42r2    Ready    infra,worker           17h   v1.32.4
hub-v57jl-worker-0-99mcp   Ready    worker                 21h   v1.32.4
hub-v57jl-worker-0-h94nj   Ready    worker                 21h   v1.32.4
```

* Capture state of node before changes

```bash
TEST_WORKER=hub-v57jl-worker-0-h94nj
mkdir $TEST_WORKER
oc get node $TEST_WORKER -o yaml > $TEST_WORKER/node-before.yaml
```

```
oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1             True      False      False      3              3                   3                     0                      21h
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718             True      False      False      6              6                   6                     0                      21h
worker-automount   rendered-worker-automount-5e9c2b6c99680f8581b1a2b42de1795c   True      False      False      0              0                   0                     0                      11h
```

* Adjust the node-role.kubernetes.io label on the test nodes so they will be configured by the worker-auomount pool which applies the automount configs and the layered image.

```bash
TEST_WORKER=hub-v57jl-worker-0-99mcp
oc label node $TEST_WORKER node-role.kubernetes.io/worker- node-role.kubernetes.io/worker-automount=''


oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1             True      False      False      3              3                   3                     0                      21h
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718             True      False      False      5              5                   5                     0                      21h
worker-automount   rendered-worker-automount-5e9c2b6c99680f8581b1a2b42de1795c   False     False      False      1              0                   0                     0                      11h
```

* Notice there is 1 mahcine in the worker-automount MCP. Un pause the MCP

```bash
oc patch machineconfigpool/worker-automount \
    --type merge --patch '{"spec":{"paused":false}}'
```
* Begin watching the MCD logs in another terminal

```bash
 oc get pods -n openshift-machine-config-operator -o wide | grep $TEST_WORKER
kube-rbac-proxy-crio-hub-v57jl-worker-0-h94nj                   1/1     Running   5 (21h ago)   21h     192.168.4.79    hub-v57jl-worker-0-h94nj   <none>           <none>
machine-config-daemon-779hx                                     2/2     Running   1 (21h ago)   21h     192.168.4.79    hub-v57jl-worker-0-h94nj   <none>           <none>

oc logs -n openshift-machine-config-operator machine-config-daemon-779hx -f
```

# References

* https://access.redhat.com/solutions/4970731
* https://access.redhat.com/solutions/5598401
* https://redhat-internal.slack.com/archives/C02CZNQHGN8/p1747245572935239
* https://issues.redhat.com//browse/OCPBUGS-53408
* https://access.redhat.com/downloads/content/479/ver=/rhel---9/9.1/x86_64/packages

<!-- * Opened bug https://issues.redhat.com/browse/OCPBUGS-56279
* Which seems to be this https://issues.redhat.com//browse/OCPBUGS-53408 -->
