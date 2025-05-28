# Using CoreOS Image Layering to run automountd on OpenShift Nodes

RHEL CoreOS is a container optimized operating system which is distributed via a container image. Typically one does not install software directly into the host operating system, but instead from pulled images running in containers.

The [RHCOS Image Layering](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/machine_configuration/mco-coreos-layering) feature of OpenShift allows to the ability to install software at the host level in a manner compatible with the automated node lifecycle management performed by OpenShift.

> [!IMPORTANT]
> On cluster image layering is TP as of 4.18 and anticipated to GA in 4.19.
>
> Draft 4.19 docs:
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

* ✅ Testing on OpenShift 4.19rc2 MachineOSConfig v1 was successful. (Caveat [this bug](https://issues.redhat.com/browse/OCPBUGS-56648))
* ❌ Testing on OpenShift 4.18.10 MachineOSConfig v1alpha1 was not successful.

## Provision Image Registry to hold layered image

Identify a registry or [enable the on-cluster registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/registry/setting-up-and-configuring-the-registry#configuring-registry-storage-baremetal)

> [!NOTE]
> Using the on-cluster image registry.
> Adapt if using an external registry.

* Create a PVC on non-default SC for Image Registry storage

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

* Enable the on cluster registry using the above PVC. 

```bash
# Enable registry - if none exists outside cluster
$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"managementState":"Managed"}}'

$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"storage":{"pvc":{"claim":"image-registry-storage-cephfs"}}}}'

# account for pvc
$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"rolloutStrategy":"Recreate"}}'
```

* Optionally [expose the registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/registry/securing-exposing-registry#securing-exposing-registry) for testing pulls off-cluster.

```bash
# Expose registry
$ oc patch configs.imageregistry.operator.openshift.io/cluster \
    --patch '{"spec":{"defaultRoute":true}}' --type=merge
```

## Pull and Push Secrets

Create a pull-secret with the ability to push to the cluster image registry in the `openshift-machine-config-operator` namespace. 

* Create a long duration token (2 year here) per this KCS https://access.redhat.com/solutions/7025261

```bash
export REGISTRY=image-registry.openshift-image-registry.svc:5000
# this user is not in the `-n openshift-machine-config-operator rolebinding/sytem:image-builder`
#export REGISTRY_USER=machine-os-builder
# this user is
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
> {"aud":["https://kubernetes.default.svc"],"exp":1810409199,"iat":1748201199,"iss":"https://kubernetes.default.svc","jti":"f47fdbe6-575b-4187-a678-74839a63ca06","kubernetes.io":{"namespace":"openshift-machine-config-operator","serviceaccount":{"name":"builder","uid":"7f114eb8-da6b-4be1-8bc4-6c9e9119a252"}},"nbf":1748201199,"sub":"system:serviceaccount:openshift-machine-config-operator:builder"}%
>
> `date -r 1810409199`
> Sat May 15 12:26:39 PDT 2027

* Extract the global pull secret to a file

```bash
oc extract secret/pull-secret -n openshift-config --to=- > pull-secret.json

cat pull-secret.json| jq '.auths|keys[]'
"cloud.openshift.com"
"quay.io"
"registry.connect.redhat.com"
"registry.redhat.io"
```

* Extract the created push secret to a file

```bash
oc extract secret/push-secret -n openshift-machine-config-operator --to=- > push-secret.json

cat push-secret.json| jq '.auths|keys[]'
"image-registry.openshift-image-registry.svc:5000"
```

* Combine the global pull secret and the just created push secret into a new pull secret. Refer to this secret in the `MachineOSConfig.spec.baseImagePullSecret` later.

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

# Deployment

## Build Configs and Layered Image

* Create [worker-automount machineconfigpool](machineconfigpool.yaml) to use for initial testing of the image build. Ensure the MCP is initially **paused**.

```bash
oc create -f machineconfigpool.yaml

oc get machineconfigpools
NAME               CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1   True      False      False      3              3                   3                     0                      6d
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718   True      False      False      6              6                   6                     0                      6d
worker-automount                                                                                                                                                                      5s
```


> [!NOTE]
> **Entitlements**
>
> Entitlement to download RPMs are enabled by an automatic copy of the `etc-pki-entitlement` secret from the `openshift-config-managed` namespace into the openshift-machine-config-operator namespace.

* Create the MachineOSConfig to define and begin the image build.

```bash
oc create -f machineosconfig.yaml
machineosconfig.machineconfiguration.openshift.io/worker-automount created

# confirm the entitlement secret was copied from openshift-config-managed
oc get secrets -n openshift-machine-config-operator | grep entitle
etc-pki-entitlement-worker-automount        Opaque                                2      2s
```

* A Job in the openshift-machine-config-operator namespace defined by the machineosconfig will create a `MachineOSBuild` and being a build.

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

* Pod start up takes a couple of minutes. Watch the logs and confirm a successful push of the resulting image.

Push FAILED
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

> [!NOTE]
> Creating or modifying MachineConfigs will trigger a new MachineOSBuild.

## Apply Layered Image to Nodes

* View current state

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
export TEST_WORKER=hub-v57jl-worker-0-8thc7
```

* Adjust the `node-role.kubernetes.io` label on the test node so it will be configured by the "worker-auomount" pool which applies the layered image.

```bash
oc label node $TEST_WORKER node-role.kubernetes.io/worker- node-role.kubernetes.io/worker-automount=''

oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1             True      False      False      3              3                   3                     0                      6d3h
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718             True      False      False      5              5                   5                     0                      6d3h
worker-automount   rendered-worker-automount-31fcb7e2bf69aaeacc1da796f6d5678e   False     False      False      1              0                   0                     0                      3h13m
```

* Notice there is 1 machine in the worker-automount Machine Config Pool. 
* Unpause the MCP to begin updating that machine

```bash
oc patch machineconfigpool/worker-automount \
    --type merge --patch '{"spec":{"paused":false}}'

oc get mcp worker-automount
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
worker-automount   rendered-worker-automount-31fcb7e2bf69aaeacc1da796f6d5678e   False     True       False      1              0                   0                     0                      3h15m

oc get nodes $TEST_WORKER
NAME                       STATUS                     ROLES              AGE     VERSION
hub-v57jl-worker-0-8thc7   Ready,SchedulingDisabled   worker-automount   3h32m   v1.32.4
```

* Begin watching the Machine Config Daemon logs for this node in another terminal

```bash
oc get pods -n openshift-machine-config-operator -o wide | grep $TEST_WORKER
kube-rbac-proxy-crio-hub-v57jl-worker-0-8thc7   1/1     Running   2 (3h31m ago)   3h30m   192.168.4.148   hub-v57jl-worker-0-8thc7   <none>           <none>
machine-config-daemon-bwq89                     2/2     Running   0               3h30m   192.168.4.148   hub-v57jl-worker-0-8thc7   <none>           <none>

oc logs -n openshift-machine-config-operator -f machine-config-daemon-bwq89
...
I0525 20:14:35.568123 3459 update.go:2741] Running: rpm-ostree cleanup -p
Deployments unchanged.
I0525 20:14:35.669725 3459 update.go:2693] Updating OS to layered image "image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:c0c5e5754d0dfc185d28f93c0f365c763bcb647b581c3f6bd3bd37a7f3dc5ba5"
I0525 20:14:35.669796 3459 image_manager_helper.go:92] Running captured: rpm-ostree --version
I0525 20:14:35.702277 3459 image_manager_helper.go:194] Linking rpm-ostree authfile to /etc/mco/internal-registry-pull-secret.json
I0525 20:14:35.702360 3459 rpm-ostree.go:183] Executing rebase to image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:c0c5e5754d0dfc185d28f93c0f365c763bcb647b581c3f6bd3bd37a7f3dc5ba5
I0525 20:14:35.702387 3459 update.go:2741] Running: rpm-ostree rebase --experimental ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:c0c5e5754d0dfc185d28f93c0f365c763bcb647b581c3f6bd3bd37a7f3dc5ba5
Pulling manifest: ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:c0c5e5754d0dfc185d28f93c0f365c763bcb647b581c3f6bd3bd37a7f3dc5ba5
Importing: ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:c0c5e5754d0dfc185d28f93c0f365c763bcb647b581c3f6bd3bd37a7f3dc5ba5 (digest: sha256:c0c5e5754d0dfc185d28f93c0f365c763bcb647b581c3f6bd3bd37a7f3dc5ba5)
ostree chunk layers already present: 51
custom layers already present: 2
custom layers needed: 2 (18.0?MB)
[0/2] Fetching layer 55fc5bbdeea1d9e6854 (1.4 MB)...done
[1/2] Fetching layer 9cbe6a42d812decb3ef (16.6 MB)...done
Staging deployment...done
Added:
autofs-1:5.1.7-60.el9.x86_64
libsss_autofs-2.9.6-4.el9_6.2.x86_64
openldap-clients-2.6.8-4.el9.x86_64
Changes queued for next boot. Run "systemctl reboot" to start a reboot
...
I0525 20:24:41.871735 3459 update.go:2277] Could not reset unit preset for ipsec.service, skipping. (Error msg: error running preset on unit: Failed to preset unit: Unit file ipsec.service does not exist.
)
I0525 20:24:41.871779 3459 file_writers.go:294] Writing systemd unit "kubelet-auto-node-size.service"
I0525 20:24:41.888322 3459 file_writers.go:294] Writing systemd unit "kubelet-dependencies.target"
I0525 20:24:42.834452 3459 update.go:2240] Preset systemd unit "kubelet-dependencies.target"
I0525 20:24:42.834486 3459 file_writers.go:208] Writing systemd unit dropin "01-kubens.conf"
I0525 20:24:42.839658 3459 file_writers.go:194] Dropin for 10-mco-default-env.conf has no content, skipping write
I0525 20:24:42.839703 3459 file_writers.go:208] Writing systemd unit dropin "10-mco-on-prem-wait-resolv.conf"
I0525 20:24:42.841951 3459 file_writers.go:208] Writing systemd unit dropin "10-mco-default-madv.conf"
I0525 20:24:42.843904 3459 file_writers.go:294] Writing systemd unit "kubelet.service"
I0525 20:24:42.861748 3459 file_writers.go:294] Writing systemd unit "kubens.service"
I0525 20:24:42.877907 3459 file_writers.go:294] Writing systemd unit "machine-config-daemon-firstboot.service"
I0525 20:24:42.893382 3459 file_writers.go:294] Writing systemd unit "machine-config-daemon-pull.service"
I0525 20:24:42.908275 3459 file_writers.go:294] Writing systemd unit "nmstate-configuration.service"
I0525 20:24:42.922699 3459 file_writers.go:294] Writing systemd unit "node-valid-hostname.service"
I0525 20:24:42.939197 3459 file_writers.go:294] Writing systemd unit "nodeip-configuration-vsphere-upi.service"
I0525 20:24:42.957322 3459 file_writers.go:294] Writing systemd unit "nodeip-configuration.service"
I0525 20:24:42.973771 3459 file_writers.go:294] Writing systemd unit "on-prem-resolv-prepender.path"
I0525 20:24:42.990781 3459 file_writers.go:294] Writing systemd unit "on-prem-resolv-prepender.service"
I0525 20:24:43.006576 3459 file_writers.go:294] Writing systemd unit "ovs-configuration.service"
I0525 20:24:43.025021 3459 file_writers.go:208] Writing systemd unit dropin "10-ovs-vswitchd-restart.conf"
I0525 20:24:44.031059 3459 update.go:2240] Preset systemd unit "ovs-vswitchd.service"
I0525 20:24:44.031093 3459 file_writers.go:208] Writing systemd unit dropin "10-ovsdb-restart.conf"
I0525 20:24:44.032005 3459 file_writers.go:194] Dropin for 10-mco-default-env.conf has no content, skipping write
I0525 20:24:44.886229 3459 update.go:2240] Preset systemd unit "rpm-ostreed.service"
I0525 20:24:44.886283 3459 file_writers.go:294] Writing systemd unit "vsphere-hostname.service"
I0525 20:24:44.920913 3459 file_writers.go:294] Writing systemd unit "wait-for-br-ex-up.service"
I0525 20:24:44.947279 3459 file_writers.go:294] Writing systemd unit "wait-for-ipsec-connect.service"
I0525 20:24:44.974165 3459 file_writers.go:294] Writing systemd unit "wait-for-primary-ip.service"
I0525 20:24:44.995402 3459 file_writers.go:208] Writing systemd unit dropin "mco-disabled.conf"
I0525 20:24:45.019360 3459 update.go:2277] Could not reset unit preset for zincati.service, skipping. (Error msg: error running preset on unit: Failed to preset unit: Unit file zincati.service does not exist.
)
I0525 20:24:45.019428 3459 file_writers.go:294] Writing systemd unit "kubelet-cleanup.service"
I0525 20:24:45.043579 3459 file_writers.go:294] Writing systemd unit "setsebool-nfs-home.service"
I0525 20:24:45.115417 3459 update.go:2873] Already in desired image quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:bb63b13cb9cd0b8c4398f17498f004aff2e7ad770f28c84dc532069ae3a76526
I0525 20:24:45.115451 3459 update.go:2741] Running: rpm-ostree cleanup -p
Pruned images: 1 (layers: 2)
Freed: 59.0?MB (pkgcache branches: 0)
I0525 20:24:47.976793 3459 update.go:2817] Removing SIGTERM protection
E0525 20:24:47.976850 3459 writer.go:226] Marking Degraded due to: "error enabling units: Failed to enable unit: Unit file autofs.service does not exist.\n"
...
```

## Use MachineConfigs to Configure and Enable Automountd

>[!NOTE]
> I have not _yet_ tested the workaround described in the following warning, but it _should_ work.

> [!WARNING]
> **Do not apply the MachineConfigs until _after_ the node is running the new image.**
>
> * https://issues.redhat.com/browse/OCPBUGS-56648
> * This means an additional imagebuild and reboot will happen.
> * Another workaround may be to create 2 MachineOSConfigs and 2 MCP. The first has no machineconfigs and is a transitory MCP.
> * The second uses the same image but includes the Machineconfigs.

Use a MachineConfig resources to enable autofs and apply necessary configuration files to the nodes.  These should be associated with the just created `worker-automount` machine config pool.


> [!IMPORTANT]
> CoreOS uses `/var/home` for user home dirs. We (configure sssd to override)[scripts/homedir.conf] the path returned from LDAP before mounting.

* Ensure that [butane `*.bu` files](machineconfigs/) and the included [scripts](scripts/) are up to date, and regenerate if necessary.

```bash
cd machineconfigs
make
```

* Adjust the role label in the [kustomization.yaml](machineconfigs/kustomization.yaml) if necessary to match the desired machineconfigpool (_worker-automount_).

* Apply all of the [machineconfigs](machineconfigs/kustomization.yaml) using kustomize or just `oc apply` the individual YAMLs.

```bash
oc apply -k machineconfigs
machineconfig.machineconfiguration.openshift.io/99-worker-automount-autofs created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-nfs-homedir-setsebool created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-sssd created
```

* This will cause another reboot of the node as the MachineConfigPool is updated.

# Debugging
## Debug Failed MCP Update 2025-05-26

Machineconfig seems to apply (i.e. /etc/sssd/conf.d/homedir.conf was written) but OS Image does not apply.

* [Full node MCD log](./hub-v57jl-worker-0-dn4tm.mcd.log)

```bash
[root@hub-v57jl-worker-0-dn4tm ~]# rpm-ostree status -v
State: busy
AutomaticUpdates: disabled
Transaction: rebase --experimental 'ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:a18f86073faf0659cfdf8753a2dc0697126515c264b2ce7da2a3b3b6f9931f7e'

  Initiator: client(id:machine-config-operator dbus:1.8151 unit:crio-8ce30d46daaa44c80724020560851c8077761590c768e7fab07a38897a1ac296.scope uid:0)
Deployments:
● ostree-unverified-registry:quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:bb63b13cb9cd0b8c4398f17498f004aff2e7ad770f28c84dc532069ae3a76526 (index: 0)
                   Digest: sha256:bb63b13cb9cd0b8c4398f17498f004aff2e7ad770f28c84dc532069ae3a76526
                  Version: 9.6.20250514-0 (2025-05-14T23:44:17Z)
                   Commit: c59fb73267cf3c6c6c44813dd3238888b9c500c8f7bee9521126079f6d455c29
                   Staged: no
                StateRoot: rhcos

# Pulling with /var/lib/kubelet/config.json does not work but /etc/mco/internal-registry-pull-secret.json does
[root@hub-v57jl-worker-0-dn4tm mco]# podman pull --authfile /etc/mco/internal-registry-pull-secret.json image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:a18f86073faf0659cfdf8753a2dc0697126515c264b2ce7da2a3b3b6f9931f7e
Trying to pull image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:a18f86073faf0659cfdf8753a2dc0697126515c264b2ce7da2a3b3b6f9931f7e...
Getting image source signatures
Copying blob 8552e7a85c92 skipped: already exists
Copying blob 71721122e569 skipped: already exists
Copying blob 13e28b74b412 skipped: already exists
Copying blob 2616319dd0b6 skipped: already exists
Copying blob f76bdafcae74 skipped: already exists
Copying blob 9ad3fd294b52 skipped: already exists
Copying blob 9b13a23c869f skipped: already exists
Copying blob 57efe3163425 skipped: already exists
Copying blob 1c21b7fdab24 skipped: already exists
Copying blob c77168d99d3c skipped: already exists
Copying blob c0edf73ad374 skipped: already exists
Copying blob d72350910969 skipped: already exists
Copying blob a7d8055279dc skipped: already exists
Copying blob dbe6e35d1324 skipped: already exists
Copying blob 86dd130c82b8 skipped: already exists
Copying blob 43dfcb10b34f skipped: already exists
Copying blob 7b090b813be3 skipped: already exists
Copying blob 00baa96f6230 skipped: already exists
Copying blob 74ad4e117528 skipped: already exists
Copying blob 548bb8e38df2 skipped: already exists
Copying blob 33ed4bd82eee skipped: already exists
Copying blob 9d30772dfd48 skipped: already exists
Copying blob 4696487faff7 skipped: already exists
Copying blob e12bf279c043 skipped: already exists
Copying blob 24abc80a6dbf skipped: already exists
Copying blob f65b36dff745 skipped: already exists
Copying blob f2dd23180414 skipped: already exists
Copying blob f73207ff9240 skipped: already exists
Copying blob 8b62e111a9b7 skipped: already exists
Copying blob cb319d70da5e skipped: already exists
Copying blob 00e24dc97786 skipped: already exists
Copying blob 99b100f4aa2f skipped: already exists
Copying blob cbc00d7179ab skipped: already exists
Copying blob 5479e2bbc9cb skipped: already exists
Copying blob 251b5f43edf7 skipped: already exists
Copying blob bd7b3c980c8f skipped: already exists
Copying blob 91982cedf9c2 skipped: already exists
Copying blob 48844b90a6c9 skipped: already exists
Copying blob 2a34404056f8 skipped: already exists
Copying blob 595813649d13 skipped: already exists
Copying blob f26f793252f5 skipped: already exists
Copying blob 8e8e44669fd1 skipped: already exists
Copying blob c639dcdae0ff skipped: already exists
Copying blob 3202adf0a72b skipped: already exists
Copying blob 176cfcfdcfdb skipped: already exists
Copying blob 082f42ad8236 skipped: already exists
Copying blob c1a31ba9dbc7 skipped: already exists
Copying blob 0c9fb1e1605c skipped: already exists
Copying blob c0f983ada380 skipped: already exists
Copying blob 256c087f65fc skipped: already exists
Copying blob ad312c5c40cc skipped: already exists
Copying blob 3cefea365c61 skipped: already exists
Copying blob 1e8bd20f9c81 skipped: already exists
Copying blob 1f51303d225d done   |
Copying blob 5d877c30355f done   |
Copying config 54c58bb1b7 done   |
Writing manifest to image destination
54c58bb1b721d0dd10ca19b8948972b11c6f5c0c30b627fd16525dcfe65ac314
```

### Workaround Testing 2025-05-27

It seems if we let the image apply without any related Machineconfigs we will avoid the above. This means an additional image build and reboot is needed.

```bash
# remove all machineconfigs from the worker-automount MCP
oc delete -k machineconfigs
machineconfig.machineconfiguration.openshift.io "99-worker-automount-autofs" deleted
machineconfig.machineconfiguration.openshift.io "99-worker-automount-nfs-homedir-setsebool" deleted
machineconfig.machineconfiguration.openshift.io "99-worker-automount-sssd" deleted

# don't forget cruft machineconfigs created before
oc delete machineconfigs -l machineconfiguration.openshift.io/role=worker-automount
machineconfig.machineconfiguration.openshift.io "99-worker-automount-autofs-service" deleted
machineconfig.machineconfiguration.openshift.io "99-worker-automount-sssd-config" deleted


# no nodes in the worker-automount MCP
oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1             True      False      False      3              3                   3                     0                      8d
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718             True      False      False      6              6                   6                     0                      8d
worker-automount   rendered-worker-automount-282653962a2d3a7860480d87467a48f7   True      False      False      0              0                   0                     0                      2d7h

oc get nodes
NAME                       STATUS   ROLES                  AGE    VERSION
hub-v57jl-master-0         Ready    control-plane,master   8d     v1.32.4
hub-v57jl-master-1         Ready    control-plane,master   8d     v1.32.4
hub-v57jl-master-2         Ready    control-plane,master   8d     v1.32.4
hub-v57jl-store-1-wqqb7    Ready    infra,worker           8d     v1.32.4
hub-v57jl-store-2-2hhjk    Ready    infra,worker           8d     v1.32.4
hub-v57jl-store-3-q42r2    Ready    infra,worker           8d     v1.32.4
hub-v57jl-worker-0-4pgbn   Ready    worker                 9h     v1.32.4
hub-v57jl-worker-0-5z4gs   Ready    worker                 2d1h   v1.32.4
hub-v57jl-worker-0-vcl9c   Ready    worker                 9h     v1.32.4

# label a node and wait to see if it gets the new image applied successfully
export TEST_WORKER=hub-v57jl-worker-0-5z4gs
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

# watch mcd logs
oc get pods -o wide -n openshift-machine-config-operator | grep $TEST_WORKER
kube-rbac-proxy-crio-hub-v57jl-worker-0-5z4gs                   1/1     Running   3 (2d1h ago)    2d1h    192.168.4.151   hub-v57jl-worker-0-5z4gs   <none>           <none>
machine-config-daemon-ts6hl                                     2/2     Running   0               2d1h    192.168.4.151   hub-v57jl-worker-0-5z4gs   <none>           <none>

oc logs -f machine-config-daemon-ts6hl -n openshift-machine-config-operator -f
```

* it takes a handful of minutes before the node was cordoned i think a machineosbuild may have occured

```bash
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
I0528 00:32:07.078202    3662 file_writers.go:234] Writing file "/usr/local/bin/nm-clean-initrd-state.sh"
I0528 00:32:07.098618    3662 file_writers.go:234] Writing file "/etc/NetworkManager/conf.d/01-ipv6.conf"
I0528 00:32:07.121880    3662 file_writers.go:234] Writing file "/etc/NetworkManager/conf.d/20-keyfiles.conf"
I0528 00:32:07.136609    3662 file_writers.go:234] Writing file "/etc/NetworkManager/conf.d/99-vsphere.conf"
I0528 00:32:07.150737    3662 file_writers.go:234] Writing file "/etc/NetworkManager/dispatcher.d/30-resolv-prepender"
I0528 00:32:07.168579    3662 file_writers.go:234] Writing file "/etc/pki/ca-trust/source/anchors/openshift-config-user-ca-bundle.crt"
I0528 00:32:07.184183    3662 file_writers.go:234] Writing file "/etc/kubernetes/apiserver-url.env"
I0528 00:32:07.200145    3662 file_writers.go:234] Writing file "/etc/audit/rules.d/mco-audit-quiet-containers.rules"
I0528 00:32:07.217912    3662 file_writers.go:234] Writing file "/etc/keepalived/monitor.conf"
I0528 00:32:07.232547    3662 file_writers.go:234] Writing file "/etc/NetworkManager/dispatcher.d/99-esp-offload"
I0528 00:32:07.249396    3662 file_writers.go:234] Writing file "/etc/tmpfiles.d/cleanup-cni.conf"
I0528 00:32:07.267070    3662 file_writers.go:234] Writing file "/usr/local/bin/configure-ip-forwarding.sh"
I0528 00:32:07.285470    3662 file_writers.go:234] Writing file "/usr/local/bin/configure-ovs.sh"
...
I0528 00:32:07.325144    3662 file_writers.go:234] Writing file "/etc/kubernetes/static-pod-resources/coredns/Corefile.tmpl"                                                                                                       I0528 00:32:07.341488    3662 file_writers.go:234] Writing file "/etc/kubernetes/manifests/coredns.yaml"
I0528 00:32:07.356542    3662 file_writers.go:234] Writing file "/etc/docker/certs.d/.create"
I0528 00:32:07.373459    3662 file_writers.go:234] Writing file "/etc/mco/proxy.env"
I0528 00:32:07.390397    3662 file_writers.go:234] Writing file "/etc/systemd/system.conf.d/10-default-env-godebug.conf"
I0528 00:32:07.406191    3662 file_writers.go:234] Writing file "/etc/NetworkManager/dispatcher.d/99-gcp-disable-idpf-tx-checksum-off"
I0528 00:32:07.423404    3662 file_writers.go:234] Writing file "/etc/modules-load.d/iptables.conf"
I0528 00:32:07.443127    3662 file_writers.go:234] Writing file "/etc/kubernetes/static-pod-resources/keepalived/keepalived.conf.tmpl"
I0528 00:32:07.459360    3662 file_writers.go:234] Writing file "/etc/kubernetes/static-pod-resources/keepalived/scripts/chk_default_ingress.sh.tmpl"                                                                              I0528 00:32:07.476355    3662 file_writers.go:234] Writing file "/etc/kubernetes/manifests/keepalived.yaml"
I0528 00:32:07.497417    3662 file_writers.go:234] Writing file "/etc/node-sizing-enabled.env"
I0528 00:32:07.512697    3662 file_writers.go:234] Writing file "/usr/local/sbin/dynamic-system-reserved-calc.sh"
I0528 00:32:07.527891    3662 file_writers.go:234] Writing file "/etc/systemd/system.conf.d/kubelet-cgroups.conf"                                                                                                                  I0528 00:32:07.541945    3662 file_writers.go:234] Writing file "/etc/systemd/system/kubelet.service.d/20-logging.conf"
I0528 00:32:07.557819    3662 file_writers.go:234] Writing file "/etc/NetworkManager/conf.d/sdn.conf"
I0528 00:32:07.571817    3662 file_writers.go:234] Writing file "/usr/local/bin/nmstate-configuration.sh"
...
I0528 00:32:11.335623    3662 update.go:2277] Could not reset unit preset for ipsec.service, skipping. (Error msg: error running preset on unit: Failed to preset unit: Unit file ipsec.service does not exist.
)
I0528 00:32:11.335826    3662 file_writers.go:294] Writing systemd unit "kubelet-auto-node-size.service"
I0528 00:32:11.352657    3662 file_writers.go:307] Disabling systemd unit kubelet-auto-node-size.service before re-writing it
I0528 00:32:12.277828    3662 file_writers.go:294] Writing systemd unit "kubelet-dependencies.target"
I0528 00:32:13.449716    3662 update.go:2240] Preset systemd unit "kubelet-dependencies.target"
I0528 00:32:13.449961    3662 file_writers.go:208] Writing systemd unit dropin "01-kubens.conf"
I0528 00:32:13.451414    3662 file_writers.go:194] Dropin for 10-mco-default-env.conf has no content, skipping write
I0528 00:32:13.451534    3662 file_writers.go:201] Removing "/etc/systemd/system/kubelet.service.d/10-mco-default-env.conf", updated file has zero length
I0528 00:32:13.451639    3662 file_writers.go:208] Writing systemd unit dropin "10-mco-on-prem-wait-resolv.conf"
I0528 00:32:13.452385    3662 file_writers.go:208] Writing systemd unit dropin "10-mco-default-madv.conf"
I0528 00:32:13.452877    3662 file_writers.go:294] Writing systemd unit "kubelet.service"
I0528 00:32:13.473182    3662 file_writers.go:307] Disabling systemd unit kubelet.service before re-writing it
I0528 00:32:14.612413    3662 file_writers.go:294] Writing systemd unit "kubens.service"
I0528 00:32:14.635457    3662 file_writers.go:294] Writing systemd unit "machine-config-daemon-firstboot.service"
I0528 00:32:14.655239    3662 file_writers.go:307] Disabling systemd unit machine-config-daemon-firstboot.service before re-writing it
I0528 00:32:15.617185    3662 file_writers.go:294] Writing systemd unit "machine-config-daemon-pull.service"
I0528 00:32:15.639073    3662 file_writers.go:307] Disabling systemd unit machine-config-daemon-pull.service before re-writing it
I0528 00:32:16.912917    3662 file_writers.go:294] Writing systemd unit "nmstate-configuration.service"
I0528 00:32:16.937426    3662 file_writers.go:307] Disabling systemd unit nmstate-configuration.service before re-writing it
I0528 00:32:17.817179    3662 file_writers.go:294] Writing systemd unit "node-valid-hostname.service"
I0528 00:32:17.835273    3662 file_writers.go:307] Disabling systemd unit node-valid-hostname.service before re-writing it
I0528 00:32:19.184694    3662 file_writers.go:294] Writing systemd unit "nodeip-configuration-vsphere-upi.service"
I0528 00:32:19.212256    3662 file_writers.go:294] Writing systemd unit "nodeip-configuration.service"
I0528 00:32:19.240152    3662 file_writers.go:307] Disabling systemd unit nodeip-configuration.service before re-writing it
I0528 00:32:20.606824    3662 file_writers.go:294] Writing systemd unit "on-prem-resolv-prepender.path"
I0528 00:32:20.633426    3662 file_writers.go:307] Disabling systemd unit on-prem-resolv-prepender.path before re-writing it
I0528 00:32:21.677791    3662 file_writers.go:294] Writing systemd unit "on-prem-resolv-prepender.service"
I0528 00:32:21.701174    3662 file_writers.go:294] Writing systemd unit "ovs-configuration.service"
I0528 00:32:21.719755    3662 file_writers.go:307] Disabling systemd unit ovs-configuration.service before re-writing it
I0528 00:32:22.661998    3662 file_writers.go:208] Writing systemd unit dropin "10-ovs-vswitchd-restart.conf"
I0528 00:32:23.742611    3662 update.go:2240] Preset systemd unit "ovs-vswitchd.service"
I0528 00:32:23.742697    3662 file_writers.go:208] Writing systemd unit dropin "10-ovsdb-restart.conf"
I0528 00:32:23.743951    3662 file_writers.go:194] Dropin for 10-mco-default-env.conf has no content, skipping write
I0528 00:32:23.743994    3662 file_writers.go:201] Removing "/etc/systemd/system/rpm-ostreed.service.d/10-mco-default-env.conf", updated file has zero length
I0528 00:32:24.749332    3662 update.go:2240] Preset systemd unit "rpm-ostreed.service"
I0528 00:32:24.749397    3662 file_writers.go:294] Writing systemd unit "vsphere-hostname.service"
I0528 00:32:24.769767    3662 file_writers.go:307] Disabling systemd unit vsphere-hostname.service before re-writing it
I0528 00:32:25.851204    3662 file_writers.go:294] Writing systemd unit "wait-for-br-ex-up.service"
I0528 00:32:25.881418    3662 file_writers.go:307] Disabling systemd unit wait-for-br-ex-up.service before re-writing it
I0528 00:32:26.872295    3662 file_writers.go:294] Writing systemd unit "wait-for-ipsec-connect.service"
I0528 00:32:26.898487    3662 file_writers.go:307] Disabling systemd unit wait-for-ipsec-connect.service before re-writing it
I0528 00:32:27.864035    3662 file_writers.go:294] Writing systemd unit "wait-for-primary-ip.service"
I0528 00:32:27.881444    3662 file_writers.go:307] Disabling systemd unit wait-for-primary-ip.service before re-writing it
I0528 00:32:28.859024    3662 file_writers.go:208] Writing systemd unit dropin "mco-disabled.conf"
I0528 00:32:28.880708    3662 update.go:2277] Could not reset unit preset for zincati.service, skipping. (Error msg: error running preset on unit: Failed to preset unit: Unit file zincati.service does not exist.
)
I0528 00:32:28.880761    3662 file_writers.go:294] Writing systemd unit "kubelet-cleanup.service"
I0528 00:32:28.909934    3662 file_writers.go:307] Disabling systemd unit kubelet-cleanup.service before re-writing it
I0528 00:32:31.013274    3662 update.go:2218] Enabled systemd units: [NetworkManager-clean-initrd-state.service firstboot-osupdate.target kubelet-auto-node-size.service kubelet.service machine-config-daemon-firstboot.service machine-config-daemon-pull.service nmstate-configuration.service node-valid-hostname.service nodeip-configuration.service on-prem-resolv-prepender.path openvswitch.service ovs-configuration.service ovsdb-server.service vsphere-hostname.service wait-for-br-ex-up.service wait-for-ipsec-connect.service wait-for-primary-ip.service kubelet-cleanup.service]
I0528 00:32:31.994868    3662 update.go:2229] Disabled systemd units [kubens.service nodeip-configuration-vsphere-upi.service on-prem-resolv-prepender.service]
I0528 00:32:31.995099    3662 update.go:1985] Deleting stale data
I0528 00:32:31.995474    3662 update.go:2415] updating the permission of the kubeconfig to: 0o600
I0528 00:32:31.995615    3662 update.go:2381] Checking if absent users need to be disconfigured
I0528 00:32:32.047422    3662 update.go:2406] Password has been configured
I0528 00:32:32.056314    3662 update.go:2817] Removing SIGTERM protection
I0528 00:32:32.056432    3662 update.go:2786] "initiating reboot: Node will reboot into image image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:4f9960aacc27743cc08dcf1bacef86069acd00683fc9440915ec28945b35b4ba / MachineConfig rendered-worker-automount-72d38a6c7ad0b42b1106ee4cf27b5718"
I0528 00:32:32.222114    3662 update.go:2786] "reboot successful"
I0528 00:32:32.239273    3662 daemon.go:711] Node hub-v57jl-worker-0-5z4gs is queued for a reboot, skipping sync.
I0528 00:32:32.560334    3662 daemon.go:3044] Daemon logs from /var/log/pods/openshift-machine-config-operator_machine-config-daemon-ts6hl_5dc2f1ef-8e52-45e9-82d9-a9b1c5460585 preserved at /etc/machine-config-daemon/previous-logs/openshift-machine-config-operator_machine-config-daemon-ts6hl_5dc2f1ef-8e52-45e9-82d9-a9b1c5460585
I0528 00:32:32.560597    3662 daemon.go:1420] Shutting down MachineConfigDaemon
```

* After node reboot

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

* Now apply the machineconfigs to enable autofs

```bash
 oc apply -k machineconfigs
machineconfig.machineconfiguration.openshift.io/99-worker-automount-autofs created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-nfs-homedir-setsebool created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-sssd created

ioc get mcp
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

# Testing AutoFS

After above is successful, `$TEST_WORKER` reboots and begins running a custom image with autofs installed and configured.

> [!NOTE]
> These results are from 05-22-25 when everything worked.

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

# Cleanup

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
