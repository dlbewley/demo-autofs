# Using CoreOS Image Layering to run automountd on OpenShift Nodes

RHEL CoreOS is a container optimized operating system which is distributed via a container image. Typically software will not be installed directly into the host operating system, but instead provided in images running in containers.

The [RHCOS Image Layering](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/machine_configuration/mco-coreos-layering) feature of OpenShift allows to the ability to install software at the host level in a manner compatible with the automated node lifecycle management performed by OpenShift.

> [!IMPORTANT]
> On cluster image layering is TP as of 4.18 and anticipated to GA in 4.19.
>
> **Draft 4.19 docs:**
>
> * https://issues.redhat.com/browse/OSDOCS-13346
> * https://87486--ocpdocs-pr.netlify.app/openshift-enterprise/latest/machine_configuration/mco-coreos-layering.html

> [!WARNING]
> Use of image layering will lead to potentially unanticipated reboots when the CA signing cert is rotated and subsequently removed. This occurs at 80% and 100% of the cert lifetime.
> This can be obviated through a coordinated pause of the machineconfig pool.


Note the following limitations when working with the on-cluster layering feature as of 4.18:

* If you scale up a machine set that uses a custom layered image, the nodes reboot two times. The first, when the node is initially created with the base image and a second time when the custom layered image is applied.
* Node disruption policies are not supported on nodes with a custom layered image. As a result the following configuration changes cause a node reboot:
    * Modifying the configuration files in the /var or /etc directory
    * Adding or modifying a systemd service
    * Changing SSH keys
    * Removing mirroring rules from ICSP, ITMS, and IDMS objects
    * Changing the trusted CA, by updating the user-ca-bundle configmap in the openshift-config namespace

# Overview 

To apply a custom layered image to your cluster by using the on-cluster build process, make a MachineOSConfig custom resource (CR) that specifies the following parameters:

* One `MachineOSConfig` resource per machine config pool specifies:
  * the Containerfile to build
  * the machine config pool to associate the build
  * where the final image should be pushed and pulled from
  * the push and pull secrets to use with the image

# Prerequisites

## OpenShift 4.19

* ✅ Testing on OpenShift 4.19rc2 & 4.19rc4 MachineOSConfig v1 was successful. (Caveat [this bug](https://issues.redhat.com/browse/OCPBUGS-56648))
* ❌ Testing on OpenShift 4.18.10 MachineOSConfig v1alpha1 was not successful.

## Provisioning an Image Registry to hold layered image

Identify a registry or [enable the on-cluster registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/registry/setting-up-and-configuring-the-registry#configuring-registry-storage-baremetal)

> [!NOTE]
> Using the on-cluster image registry.
> Adapt if using an external registry.

* If necessary, create a PVC on a non-default StorageClass (eg ocs-storagecluster-cephfs) for the OpenShift Image Registry storage

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

* Enable the on cluster registry with the above PVC. 

```bash
# Enable registry - if none exists outside cluster
$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"managementState":"Managed"}}'

$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"storage":{"pvc":{"claim":"image-registry-storage-cephfs"}}}}'

# account for single replica, non-rolling deployment
$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"rolloutStrategy":"Recreate"}}'
```

* Optionally [expose the registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/registry/securing-exposing-registry#securing-exposing-registry) for testing pulls from off-cluster if desired.

```bash
# Expose registry
$ oc patch configs.imageregistry.operator.openshift.io/cluster \
    --patch '{"spec":{"defaultRoute":true}}' --type=merge
```

## Creating Pull and Push Secrets

Create a pull-secret with the ability to push to the cluster image registry in the `openshift-machine-config-operator` namespace. 

* Create a long duration token (2 year here) per this KCS https://access.redhat.com/solutions/7025261

```bash
export REGISTRY=image-registry.openshift-image-registry.svc:5000
# this serviceaccount is in the `-n openshift-machine-config-operator rolebinding/sytem:image-builder`
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
>
> `oc extract secret/push-secret -n openshift-machine-config-operator --to=- | jq -r '.auths."image-registry.openshift-image-registry.svc:5000".auth' | base64 -d | cut -d. -f2 | base64 -d`
> 
> {"aud":["https://kubernetes.default.svc"],"exp":1810409199,"iat":1748201199,"iss":"https://kubernetes.default.svc","jti":"f47fdbe6-575b-4187-a678-74839a63ca06","kubernetes.io":{"namespace":"openshift-machine-config-operator","serviceaccount":{"name":"builder","uid":"7f114eb8-da6b-4be1-8bc4-6c9e9119a252"}},"nbf":1748201199,"sub":"system:serviceaccount:openshift-machine-config-operator:builder"}%
>
> `date -r 1810409199`
> Sat May 15 12:26:39 PDT 2027

* Extract the created push secret to a file

```bash
oc extract secret/push-secret -n openshift-machine-config-operator --to=- > push-secret.json

cat push-secret.json| jq '.auths|keys[]'
"image-registry.openshift-image-registry.svc:5000"
```

* Extract the cluster global pull secret to a file

```bash
oc extract secret/pull-secret -n openshift-config --to=- > pull-secret.json

cat pull-secret.json| jq '.auths|keys[]'
"cloud.openshift.com"
"quay.io"
"registry.connect.redhat.com"
"registry.redhat.io"
```

* Combine the global pull secret and the just created push secret into a new pull secret.

```bash
jq -s '.[0] * .[1]' pull-secret.json push-secret.json > pull-and-push-secret.json

cat pull-and-push-secret.json| jq '.auths|keys[]'
"cloud.openshift.com"
"image-registry.openshift-image-registry.svc:5000"
"quay.io"
"registry.connect.redhat.com"
"registry.redhat.io"

oc create secret generic pull-and-push-secret \
  -n openshift-machine-config-operator \
  --from-file=.dockerconfigjson=pull-and-push-secret.json \
  --type=kubernetes.io/dockerconfigjson
```

* Refer to this combined secret in the `MachineOSConfig.spec.baseImagePullSecret`.

* Confirm the pull secret references in  [machineosconfig.yaml](machineosconfig.yaml). 

```bash
oc get secrets -n openshift-machine-config-operator |grep push
pull-and-push-secret                        kubernetes.io/dockerconfigjson        1      64s
push-secret                                 kubernetes.io/dockerconfigjson        1      7m52s

cat machineosconfig.yaml | yq '.spec | with_entries(select(.key | contains("Secret")))'

baseImagePullSecret:
  name: pull-and-push-secret
renderedImagePushSecret:
  name: push-secret
```

[![asciicast](https://asciinema.org/a/721881.svg)](https://asciinema.org/a/721881)

# Deployment

> [!WARNING]
> 🐛 Bug [OCPBUGS-56648](https://issues.redhat.com/browse/OCPBUGS-56648) requires a 2 step process of enrolling a node at this time.
> 
> Since this image adds a service (autofs) which will be enabled via MachineConfig this workaround is required:
>
> * Ensure that the custom image is applied and running on a node first
> * Only then, apply the machineconfigs that require the custom image
> * It may be best to create a transitory MCP called `worker-imaging` that nodeas pass through just for the image swap
> * Using 2 MCP also means 2 machineosconfigs and 2 image builds

## Creating the MachineConfigPool and MachineOSConfig

The [MachineOSConfig](machineosconfig.yaml) resource defines how to build the layered CoreOS image. It is assocatied with a MachineConfigPool to target the machines that should run the image.

* Create [worker-automount machineconfigpool](machineconfigpool.yaml) to use for initial testing of the image build. Ensure the MCP is initially **paused**.

This MCP will include MachineConfig resources from the existing worker role and will later include [MachineConfig resources](machineconfigs/kustimization.yaml) to configure autofs. **Do not create those yet.**

```bash
oc create -f machineconfigpool.yaml

# no nodes in the worker-automount MCP
oc get machineconfigpools
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1             True      False      False      3              3                   3                     0                      8d
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718             True      False      False      6              6                   6                     0                      8d
worker-automount   rendered-worker-automount-282653962a2d3a7860480d87467a48f7   True      False      False      0              0                   0                     0                      2d7h
```

> [!NOTE]
> **Entitlements**
>
> Entitlement to download RPMs are enabled by an automatic copy of the `etc-pki-entitlement` secret from the `openshift-config-managed` namespace into the openshift-machine-config-operator namespace.
> Your cluster global pull secret must have proper entitlement to pass on to the nodes. I _believe_ this is conveyed by having a RHN login associated with a support contract.

* Create the [`MachineOSConfig`](machineosconfig.yaml) to define and begin the image build.

```bash
oc create -f machineosconfig.yaml
machineosconfig.machineconfiguration.openshift.io/worker-automount created

# confirm the entitlement secret was copied from openshift-config-managed
oc get secrets -n openshift-machine-config-operator | grep entitle
etc-pki-entitlement-worker-automount        Opaque                                2      2s
```

* A Job in the openshift-machine-config-operator namespace will create a pod to perform the build and a `MachineOSBuild` to track the build.

```bash
oc get jobs -n openshift-machine-config-operator
NAME                                                      STATUS    COMPLETIONS   DURATION   AGE
build-worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1   Running   0/1           14s        14s

oc get machineosbuild -n openshift-machine-config-operator
NAME                                                PREPARED   BUILDING   SUCCEEDED   INTERRUPTED   FAILED   AGE
worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1   False      True       False       False         False    25s

oc get pods -n openshift-machine-config-operator |grep build
build-worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1-c65xf   2/2     Running   0               25s
machine-os-builder-57bb5fc9cc-2vx8z                             1/1     Running   0               30s
```

* Pod start up takes a couple of minutes. Watch the logs and confirm a successful access to RPM repositories and push of the resulting image.

```bash
oc logs  -n  openshift-machine-config-operator -f build-worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1-c65xf
...
Updating Subscription Management repositories.                                                                   subscription-manager is operating in container mode.                                                             Red Hat Enterprise Linux 9 for x86_64 - AppStre  20 MB/s |  60 MB     00:02                                      Red Hat Enterprise Linux 9 for x86_64 - BaseOS   22 MB/s |  58 MB     00:02                                      Last metadata expiration check: 0:00:17 ago on Sun May 25 16:45:50 2025.                                         Dependencies resolved.                                                                                           ================================================================================                                  Package          Arch   Version            Repository                     Size                                  ================================================================================                                 Installing:
 autofs           x86_64 1:5.1.7-60.el9     rhel-9-for-x86_64-baseos-rpms 391 k
 libsss_autofs    x86_64 2.9.6-4.el9_6.2    rhel-9-for-x86_64-baseos-rpms  38 k
 openldap-clients x86_64 2.6.8-4.el9        rhel-9-for-x86_64-baseos-rpms 184 k
...
+ return 0
+ retry buildah push --storage-driver vfs --authfile=/tmp/final-image-push-creds/config.json --digestfile=/tmp/do
ne/digestfile --cert-dir /var/run/secrets/kubernetes.io/serviceaccount image-registry.openshift-image-registry.sv
c:5000/openshift-machine-config-operator/os-image:worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1
+ local count=0
+ buildah push --storage-driver vfs --authfile=/tmp/final-image-push-creds/config.json --digestfile=/tmp/done/dig
estfile --cert-dir /var/run/secrets/kubernetes.io/serviceaccount image-registry.openshift-image-registry.svc:5000
/openshift-machine-config-operator/os-image:worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1
Getting image source signatures
...
Copying config sha256:c50a0e04724ae299990e1750ed70d31bb8091ac1c6c9fb714bbc121fd5312074
Writing manifest to image destination
+ return 0
```

* Check that the MachineOSBuild is successful

```bash
oc get machineosbuild -n openshift-machine-config-operator
NAME                                                PREPARED   BUILDING   SUCCEEDED   INTERRUPTED   FAILED   AGE
worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1   False      False      True        False         False    11m
```

[![asciicast](https://asciinema.org/a/722700.svg)](https://asciinema.org/a/722700)

## Applying the Layered Image to Nodes

* View the current state

```bash
oc get clusterversion
NAME      VERSION       AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.19.0-rc.2   True        False         6d2h    Cluster version is 4.19.0-rc.2

oc get nodes
NAME                       STATUS   ROLES                  AGE     VERSION
hub-v57jl-cnv-8swxv        Ready    worker                 5d18h   v1.32.4
hub-v57jl-master-0         Ready    control-plane,master   6d3h    v1.32.4
hub-v57jl-master-1         Ready    control-plane,master   6d3h    v1.32.4
hub-v57jl-master-2         Ready    control-plane,master   6d3h    v1.32.4
hub-v57jl-store-1-wqqb7    Ready    infra,worker           5d23h   v1.32.4
hub-v57jl-store-2-2hhjk    Ready    infra,worker           5d23h   v1.32.4
hub-v57jl-store-3-q42r2    Ready    infra,worker           5d23h   v1.32.4
hub-v57jl-worker-0-8thc7   Ready    worker                 3h25m   v1.32.4
hub-v57jl-worker-0-dn4tm   Ready    worker                 5d      v1.32.4

oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1             True      False      False      3              3                   3                     0                      6d3h
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718             True      False      False      6              6                   6                     0                      6d3h
worker-automount   rendered-worker-automount-31fcb7e2bf69aaeacc1da796f6d5678e   True      False      False      0              0                   0                     0                      3h10m
```

* Select a test node to work with.

```bash
export TEST_WORKER=hub-v57jl-worker-0-5z4gs
```

* Adjust the `node-role.kubernetes.io` label on the test node so it will be configured by the "worker-auomount" pool which applies the layered image.

```bash
oc label node $TEST_WORKER node-role.kubernetes.io/worker- node-role.kubernetes.io/worker-automount=''

oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1             True      False      False      3              3                   3                     0                      8d
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718             True      False      False      6              6                   6                     0                      8d
worker-automount   rendered-worker-automount-72d38a6c7ad0b42b1106ee4cf27b5718   False     True       False      1              0                   0                     0                      2d7h

# see new role on $TEST_NODE
oc get nodes
NAME                       STATUS   ROLES                  AGE    VERSION
hub-v57jl-master-0         Ready    control-plane,master   8d     v1.32.4
hub-v57jl-master-1         Ready    control-plane,master   8d     v1.32.4
hub-v57jl-master-2         Ready    control-plane,master   8d     v1.32.4
hub-v57jl-store-1-wqqb7    Ready    infra,worker           8d     v1.32.4
hub-v57jl-store-2-2hhjk    Ready    infra,worker           8d     v1.32.4
hub-v57jl-store-3-q42r2    Ready    infra,worker           8d     v1.32.4
hub-v57jl-worker-0-4pgbn   Ready    worker                 9h     v1.32.4
hub-v57jl-worker-0-5z4gs   Ready    worker-automount       2d1h   v1.32.4
hub-v57jl-worker-0-v6snn   Ready    worker                 5m7s   v1.32.4
hub-v57jl-worker-0-vcl9c   Ready    worker                 9h     v1.32.4
```

* Notice there is 1 machine in the worker-automount Machine Config Pool. 
* Unpause the MCP to begin updating that machine

```bash
oc patch machineconfigpool/worker-automount \
    --type merge --patch '{"spec":{"paused":false}}'

oc get mcp worker-automount
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
worker-automount   rendered-worker-automount-31fcb7e2bf69aaeacc1da796f6d5678e   False     True       False      1              0                   0                     0                      3h15m
```

* Begin watching the Machine Config Daemon logs for this node in another terminal

```bash
oc get pods -n openshift-machine-config-operator -o wide | grep $TEST_WORKER
kube-rbac-proxy-crio-hub-v57jl-worker-0-8thc7   1/1     Running   2 (3h31m ago)   3h30m   192.168.4.148   hub-v57jl-worker-0-8thc7   <none>           <none>
machine-config-daemon-bwq89                     2/2     Running   0               3h30m   192.168.4.148   hub-v57jl-worker-0-8thc7   <none>           <none>
```

```bash
oc logs -n openshift-machine-config-operator -f machine-config-daemon-bwq89

I0528 00:26:42.801086    3662 certificate_writer.go:294] Certificate was synced from controllerconfig resourceVersion 9501408
W0528 00:28:29.865693    3662 daemon.go:2738] Unable to check manifest for matching hash: error parsing image name "docker://quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:bb63b13cb9cd0b8c4398f17498f004aff2e7ad770f28c84dc532069ae3a76526": invalid image name "docker://quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:bb63b13cb9cd0b8c4398f17498f004aff2e7ad770f28c84dc532069ae3a76526", unknown transport "docker"
I0528 00:28:29.865723    3662 image_manager_helper.go:92] Running captured: rpm-ostree kargs
I0528 00:28:30.487694    3662 daemon.go:957] Preflight config drift check successful (took 622.035822ms)
I0528 00:28:30.492922    3662 config_drift_monitor.go:255] Config Drift Monitor has shut down
I0528 00:28:30.492969    3662 daemon.go:2580] Performing layered OS update
I0528 00:28:30.613083    3662 update.go:2808] Adding SIGTERM protection
I0528 00:28:30.613440    3662 upgrade_monitor.go:348] MCN Featuregate is not enabled. Please enable the TechPreviewNoUpgrade featureset to use MachineConfigNodes
I0528 00:28:30.691205    3662 update.go:897] Checking Reconcilable for config rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718 to rendered-worker-automount-72d38a6c7ad0b42b1106ee4cf27b5718
I0528 00:28:30.831961    3662 update.go:2786] "Update prepared; requesting cordon and drain via annotation to controller"

I0528 00:31:20.899066    3662 update.go:2786] "drain complete"
I0528 00:31:20.902671    3662 drain.go:125] Successful drain took 170.061540965 seconds
I0528 00:31:20.903027    3662 update.go:939] Old MachineConfig rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718 / Image quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:bb63b13cb9cd0b8c4398f17498f004aff2e7ad770f28c84dc532069ae3a76526 -> New MachineConfig rendered-worker-automount-72d38a6c7ad0b42b1106ee4cf27b5718 / Image image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:4f9960aacc27743cc08dcf1bacef86069acd00683fc9440915ec28945b35b4ba
I0528 00:31:20.903076    3662 update.go:2741] Running: rpm-ostree cleanup -p
Deployments unchanged.
I0528 00:31:21.208084    3662 update.go:2693] Updating OS to layered image "image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:4f9960aacc27743cc08dcf1bacef86069acd00683fc9440915ec28945b35b4ba"
I0528 00:31:21.208139    3662 image_manager_helper.go:92] Running captured: rpm-ostree --version
I0528 00:31:21.241098    3662 image_manager_helper.go:194] Linking rpm-ostree authfile to /etc/mco/internal-registry-pull-secret.json
I0528 00:31:21.241192    3662 rpm-ostree.go:183] Executing rebase to image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:4f9960aacc27743cc08dcf1bacef86069acd00683fc9440915ec28945b35b4ba
I0528 00:31:21.241210    3662 update.go:2741] Running: rpm-ostree rebase --experimental ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:4f9960aacc27743cc08dcf1bacef86069acd00683fc9440915ec28945b35b4ba
Pulling manifest: ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:4f9960aacc27743cc08dcf1bacef86069acd00683fc9440915ec28945b35b4ba
Importing: ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:4f9960aacc27743cc08dcf1bacef86069acd00683fc9440915ec28945b35b4ba (digest: sha256:4f9960aacc27743cc08dcf1bacef86069acd00683fc9440915ec28945b35b4ba)
ostree chunk layers already present: 51
custom layers already present: 2
custom layers needed: 2 (18.0?MB)
[0/2] Fetching layer 8081c56ca6e5d76bca5 (1.4 MB)...done
[1/2] Fetching layer aa669aa90b82df8c990 (16.6 MB)...done

Staging deployment...done
Added:
  autofs-1:5.1.7-60.el9.x86_64
  libsss_autofs-2.9.6-4.el9_6.2.x86_64
  openldap-clients-2.6.8-4.el9.x86_64
Changes queued for next boot. Run "systemctl reboot" to start a reboot
I0528 00:32:07.078099    3662 update.go:1922] Updating files
...
I0528 00:32:32.056432    3662 update.go:2786] "initiating reboot: Node will reboot into image image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:4f9960aacc27743cc08dcf1bacef86069acd00683fc9440915ec28945b35b4ba / MachineConfig rendered-worker-automount-72d38a6c7ad0b42b1106ee4cf27b5718"
I0528 00:32:32.222114    3662 update.go:2786] "reboot successful"
I0528 00:32:32.239273    3662 daemon.go:711] Node hub-v57jl-worker-0-5z4gs is queued for a reboot, skipping sync.
I0528 00:32:32.560334    3662 daemon.go:3044] Daemon logs from /var/log/pods/openshift-machine-config-operator_machine-config-daemon-ts6hl_5dc2f1ef-8e52-45e9-82d9-a9b1c5460585 preserved at /etc/machine-config-daemon/previous-logs/openshift-machine-config-operator_machine-config-daemon-ts6hl_5dc2f1ef-8e52-45e9-82d9-a9b1c5460585
I0528 00:32:32.560597    3662 daemon.go:1420] Shutting down MachineConfigDaemon
```

* After node reboot make sure node is Ready and MCP is not degraded

```bash
 oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1             True      False      False      3              3                   3                     0                      8d
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718             True      False      False      6              6                   6                     0                      8d
worker-automount   rendered-worker-automount-72d38a6c7ad0b42b1106ee4cf27b5718   True      False      False      1              1                   1                     0                      2d8h

oc get nodes
NAME                       STATUS   ROLES                  AGE    VERSION
hub-v57jl-master-0         Ready    control-plane,master   8d     v1.32.4
hub-v57jl-master-1         Ready    control-plane,master   8d     v1.32.4
hub-v57jl-master-2         Ready    control-plane,master   8d     v1.32.4
hub-v57jl-store-1-wqqb7    Ready    infra,worker           8d     v1.32.4
hub-v57jl-store-2-2hhjk    Ready    infra,worker           8d     v1.32.4
hub-v57jl-store-3-q42r2    Ready    infra,worker           8d     v1.32.4
hub-v57jl-worker-0-4pgbn   Ready    worker                 9h     v1.32.4
hub-v57jl-worker-0-5z4gs   Ready    worker-automount       2d2h   v1.32.4
hub-v57jl-worker-0-v6snn   Ready    worker                 18m    v1.32.4
hub-v57jl-worker-0-vcl9c   Ready    worker                 9h     v1.32.4
```

* Login and confirm the autofs RPM added to the custom image is present

```bash
oc debug node/hub-v57jl-worker-0-5z4gs
Starting pod/hub-v57jl-worker-0-5z4gs-debug-wxrm6 ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.

Pod IP: 192.168.4.151
If you don't see a command prompt, try pressing enter.
sh-5.1#
sh-5.1# chroot /host
sh-5.1# rpm -q autofs
autofs-5.1.7-60.el9.x86_64
```

[![asciicast](https://asciinema.org/a/722913.svg)](https://asciinema.org/a/722913)

## Applying the MachineConfigs to Configure and Enable Automountd

> [!WARNING]
> **Do not apply theese MachineConfigs until _after_ the node is running the new image.**
>
> 🐛 Bug [OCPBUGS-56648](https://issues.redhat.com/browse/OCPBUGS-56648)

> [!NOTE]
> Creating or modifying MachineConfigs will always trigger a new MachineOSBuild.

Use a MachineConfig resources to enable autofs and apply the necessary [configuration files](scripts/) to the nodes.  These should be associated with the just created `worker-automount` machine config pool.

> [!IMPORTANT]
> CoreOS uses `/var/home` for user home dirs. We (configure sssd to override)[scripts/homedir.conf] the path returned from LDAP before mounting.

* Ensure that [butane `*.bu` files](machineconfigs/) and the included [scripts](scripts/) are up to date, and regenerate if necessary. See also this [blog post](http://guifreelife.com/blog/2025/05/29/Managing-OpenShift-Machine-Configuration-with-Butane-and-Ignition/).

```bash
make -C machineconfigs
```

* Adjust the role label in the [kustomization.yaml](machineconfigs/kustomization.yaml) if necessary to match the desired machineconfigpool (_worker-automount_).

* Apply all of the [machineconfigs](machineconfigs/kustomization.yaml) using kustomize or just `oc apply` the individual YAMLs.

```bash
oc apply -k machineconfigs
machineconfig.machineconfiguration.openshift.io/99-worker-automount-autofs created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-nfs-homedir-setsebool created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-sssd created
```

* This will cause another image build and reboot of the node as the MachineConfigPool is updated.

* it takes a handful of minutes before the node was cordoned i think a machineosbuild may have occured


```bash
 oc apply -k machineconfigs
machineconfig.machineconfiguration.openshift.io/99-worker-automount-autofs created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-nfs-homedir-setsebool created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-sssd created

oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1             True      False      False      3              3                   3                     0                      8d
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718             True      False      False      6              6                   6                     0                      8d
worker-automount   rendered-worker-automount-72d38a6c7ad0b42b1106ee4cf27b5718   False     True       False      1              0                   0                     0                      2d8h
```

* I broke ssh logins to core, debugging tbd, but autofs is working now!

```bash
oc debug node/$TEST_WORKER
sh-5.1# chroot /host
sh-5.1# ls -a ~dale
.  ..  .bash_history  .bash_logout  .bash_profile  .bashrc  .ssh
sh-5.1# df -h ~dale
Filesystem              Size  Used Avail Use% Mounted on
nfs:/exports/home/dale   29G  2.0G   27G   7% /var/home/dale
```

[![asciicast](https://asciinema.org/a/722936.svg)](https://asciinema.org/a/722936)

# Testing AutoFS

After above is successful, `$TEST_WORKER` reboots and begins running a custom image with autofs installed and configured.

Once the node has successfully applied the custom layered image, confirm autofs functionality.

```bash
[root@hub-v57jl-worker-0-99mcp ~]# cat /etc/sssd/conf.d/homedir.conf
override_homedir = /var/home/%u

[root@hub-v57jl-worker-0-99mcp ~]# getent passwd dale
dale:*:1001:1001:Dale:/home/dale:/bin/bash

[root@hub-v57jl-worker-0-99mcp ~]# su - dale
Last login: Thu May 22 13:21:58 UTC 2025 on pts/0

[dale@hub-v57jl-worker-0-99mcp ~]$ id
uid=1001(dale) gid=1001(dale) groups=1001(dale) context=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023

[dale@hub-v57jl-worker-0-99mcp ~]$ pwd
/home/dale

[dale@hub-v57jl-worker-0-99mcp ~]$ df -h .
Filesystem              Size  Used Avail Use% Mounted on
nfs:/exports/home/dale   29G  1.8G   27G   7% /var/home/dale
```

> [!WARNING]
>️ ssh as core doesn't work yet due to squashed home dir, use oc debug/node as root as workaround


# Cleanup

* Undo all the changes to re-test
```bash
export TEST_WORKER=hub-v57jl-worker-0-99mcp

oc label node $TEST_WORKER \
  node-role.kubernetes.io/worker='' \
  node-role.kubernetes.io/worker-automount-

oc delete machineosconfigs worker-automount
oc delete machineosbuilds --all
oc delete mcp worker-automount
oc delete secret/push-secret -n openshift-machine-config-operator
oc delete secret/pull-and-push-secret -n openshift-machine-config-operator
```

# References

* https://access.redhat.com/solutions/4970731
* https://access.redhat.com/solutions/5598401
* https://redhat-internal.slack.com/archives/C02CZNQHGN8/p1747245572935239
* https://issues.redhat.com/browse/OCPBUGS-56648
* https://issues.redhat.com//browse/OCPBUGS-53408
* https://access.redhat.com/downloads/content/479/ver=/rhel---9/9.1/x86_64/packages
* [internal deck](https://docs.google.com/presentation/d/14rIn35xjR8cptqzYwDoFO6IOWIUNkSBZG3K2-5WJKok/edit?slide=id.g547716335e_0_220#slide=id.g547716335e_0_220)
* [RHCOS Image Layering 4.18 docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/machine_configuration/mco-coreos-layering) 

<!-- * Opened bug https://issues.redhat.com/browse/OCPBUGS-56279
* Which seems to be this https://issues.redhat.com//browse/OCPBUGS-53408 -->
