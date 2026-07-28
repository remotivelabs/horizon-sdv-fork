# remotive-topology

Run [RemotiveTopology](https://docs.remotivelabs.com/) vehicle-system simulations
("system of systems") on ephemeral GCE VMs, following the Horizon SDV
Packer → KCC `ComputeInstanceTemplate` → ephemeral-GCE-driver pattern
(`cf_instance_template` + `cvd_launcher` parity).

## Layout

- `topologies/getting_started/` — vendored demo topology (see `VENDORED.md` for
  provenance) plus the Horizon-specific `getting_started.launcher.yaml` descriptor.
- `pipelines/environment/docker_image_template/` — builder container image
  (packer, gcloud, kubectl) used by all remotive workflow pods; builds via
  the shared `common-docker-image-build` ClusterWorkflowTemplate (module
  workloads-common).
- `pipelines/environment/remotive_instance_template/` — Packer bake
  (Docker CE, remotivebusd, remotivelabs-cli — translation of the upstream ansible
  roles) + KCC `ComputeInstanceTemplate` publish.
- `pipelines/tests/remotive_launcher/` — ephemeral VM driver (Path B: KCC
  `ComputeInstance` + GCS message passing, no SSH from the pod) and guest scripts
  that build and run the topology.

Shared GCP REST helpers are referenced from `workloads/android/pipelines/common/gcp/`
(generic library code; the monorepo is fully cloned in workflow pods regardless of
which modules are enabled).

## Workflow order

1. `remotive-builder-image` — once, and after Dockerfile changes.
2. `remotive-instance-template` — publishes `instance-template-<instanceName>`
   (default `instance-template-remotive-vm`).
3. `remotive-launcher` — per topology run.

## One-time setup: RemotiveCloud auth Secret

Topology builds authenticate against RemotiveCloud. Create the Secret with a
**revocable, least-privilege service-account token** (never personal credentials):

```sh
kubectl -n <prefix>workflows create secret generic workflow-remotive-cloud-auth \
  --from-literal=token=<service-account-token> \
  --from-literal=organization=<organization-id>
```

The token is exported only into the topology process environment on the ephemeral
VM (not `/etc/environment` as in the upstream demo) and travels through the run's
GCS staging prefix like other job parameters — keep the token revocable.

## Running a non-vendored topology

`remotive-launcher` accepts `topologyDownloadUrl` (a `gs://bucket/dir` or an https
`.tgz`/`.tar.gz` URL) containing a self-contained topology project. The project
must include a `<topologyName>.launcher.yaml` descriptor at the project root
(the path can be overridden with the optional `launcherFile` workflow parameter,
relative to the project root):

```yaml
topology_instances: # -f flags for `remotive topology build`, in order (required, non-empty)
  - instances/main.instance.yaml
compose_overlays: [] # extra docker compose -f files
compose_profiles: [] # long-running compose profiles
test_service: tester # compose service run when runTopologyTests=true
forward_ports: # topology ports exposed as MTK Connect tunnels
  - name: RemotiveBroker # tunnel name; required, like port
    port: 50051
adb_devices: # Android adb endpoints registered as streamed MTK Connect devices
  - name: IHU # MTK device name; required, like port
    port: 6520 # adb port published by the topology (cuttlefish default)
```

`forward_ports` lists only topology ports; each entry requires both `name` (used
as the MTK Connect tunnel name and in the printed access info) and `port`. The
primary UI, RemotiveStudio, is started by the launcher on port `57123` (see
below) — not a descriptor entry.

`adb_devices` lists Android adb endpoints (e.g. a cuttlefish instance's adb
port `6520`); each entry requires both `name` and `port`, and the port must be
published by the topology's compose so it is reachable on the VM. Each entry
becomes a full MTK Connect Android device — screen streaming, adb terminal,
logcat, touch — instead of the default HOST-only device (see below). Note that
the cuttlefish web UI (port `8443`) does **not** work through a `forward_ports`
tunnel: its WebRTC media stream cannot traverse a single-port TCP tunnel, which
is exactly what `adb_devices` is for.

The descriptor and a non-empty `topology_instances` list are required — the
workflow fails immediately when either is missing. The other keys are optional
(test service defaults to `tester`, no forwarded topology ports, no adb
devices).

## Accessing a running topology

All interactive access goes through **MTK Connect** tunnels and devices. This
requires the `workflow-mtk-connect-apikey` Secret in the workflows namespace
(created by the mtk-connect module's post job and kept in sync on key rotation)
— it is **required**; without it a keep-alive run has no access path.

During the keep-alive window (`keepAliveTime` minutes) the launcher starts
**RemotiveStudio** on port `57123` (bound to `0.0.0.0`, connected to the topology
broker on `localhost:50051`) as the primary UI. RemotiveStudio (`57123`) and the
topology's `forward_ports` (e.g. broker gRPC `50051`) are exposed through MTK
Connect as raw TCP tunnels. The testbench (`remotive-launcher-<n>`) registers one
`Remotive` device with:

- **`studio` (tunnel, raw TCP)** — for the MTK Connect Tunnel client: create a
  tunnel to the testbench on local port `57123`, then browse
  `http://localhost:57123` for RemotiveStudio.
- **one tunnel (raw TCP) per `forward_port`**, named after the descriptor `name`
  — e.g. `RemotiveBroker` for the broker gRPC port `50051`; tunnels to the same
  local port.
- **`HOST` (terminal)** — a shell on the VM as the image's interactive user.

With `adb_devices` in the descriptor, the testbench instead registers one MTK
Connect **Android device per entry** (named after the descriptor `name`), each
with live screen streaming, adb + HOST terminals, logcat and touch input — the
in-browser equivalent of the cuttlefish UI, without its WebRTC limitation. The
raw TCP tunnels above (studio + `forward_ports`) are attached to the first
device.

RemotiveStudio and MTK Connect are skipped entirely when `keepAliveTime` is `0`
(e.g. a pure test run), since there is no window in which to reach them.
RemotiveStudio is started fire-and-forget: it is not stopped in teardown but goes
away with the ephemeral VM. Its log is captured in the run artifacts
(`remotive-argo-studio.log`).

## Known cross-module caveats (workloads-android)

Both this module and workloads-android publish KCC resources into the shared
`<prefix>workflows` namespace:

- **ConfigConnectorContext is a namespace singleton.** workloads-android's
  cf_instance_template chart owns it by default. Set the module config
  `manageConfigConnectorContext: true` for remotive-topology ONLY when
  workloads-android is not installed. Disabling whichever module owns the context
  removes it and breaks KCC publishing for the other.
- **workloads-android disable is aggressive.** Its CNRM PreDelete hook deletes
  _all_ `ComputeInstanceTemplate` CRs in the workflows namespace (it predates this
  module), and Module Manager's workloads-android teardown waits for _every_ CIT to
  leave the namespace. Disabling workloads-android while remotive-topology is
  enabled will therefore also remove remotive instance templates — re-run
  `remotive-instance-template` afterwards.
