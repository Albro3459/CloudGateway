# Linux test VM

Creates one throwaway Ubuntu VM in OCI for manual testing. At first boot,
cloud-init creates the `backdoor` console user from
[backdoor-cloud-init.yaml](../../../Infrastructure/OCI/terraform/backdoor-cloud-init.yaml),
then installs a published CloudGateway for Linux release with `backdoor` as the
operator. It isn't for production.

The VM joins an existing subnet, such as the Chicago server's, and gets a
public IP. The VCN, subnet, and security list are managed elsewhere.

Linux is Mesh-first, unlike macOS and iOS. Full mode is experimental and may
need provider-specific DHCP/DNS configuration. In particular, an OCI DHCP DNS
search domain can block Full. Use `cloudgateway doctor` to inspect the host.
The Mesh default is in the next release; v0.0.2 and earlier default to Full.

## Publish a test release

Cloud-init downloads `install.sh` from the `linux-v<version>` GitHub release, so
publish one first:

1. Build it as described in [Releases](../README.md#releases), with a version
   you haven't used, such as `0.1.0`.
2. Push the commit, then run the printed `gh release create` command with
   `--prerelease` added.

Use a new patch version for each round of fixes.

## Create the VM

```sh
cd Frontend/Linux/test-vm
cp terraform.tfvars.example terraform.tfvars   # fill in real values
terraform init
terraform apply
```

This folder has its own state, separate from the regional servers.

| Setting | Values |
| --- | --- |
| `arch` | `arm64` uses `VM.Standard.A1.Flex` with 1 OCPU and 1 GB. `amd64` uses `VM.Standard.E2.1.Micro` with 1/8 OCPU and 1 GB |
| `ubuntu_version` | Any Ubuntu release OCI has an image for, such as `24.04` or `26.04` |
| `release_version` | The `linux-v<version>` release to install |

Both shapes are Always Free. `E2.1.Micro` is free only in the tenancy's home
region. `A1.Flex` sometimes fails with "Out of host capacity". Retry later or
switch `arch`.

Changing any setting replaces the VM on the next apply. So does a newer OCI
image for that Ubuntu release. The plan shows the replacement.

## Connect

Use the console, since Full mode can cut SSH:

1. Open the instance in OCI.
2. Under **OS Management**, find **Console connection** and select **Launch
   Cloud Shell connection**.
3. Once it loads, press Enter and log in as `backdoor` with the password you
   hashed.

`backdoor` is the operator, so `cloudgateway` runs without sudo. Check the
install with `cloud-init status --wait`, then
`sudo tail -n 50 /var/log/cloud-init-output.log`. Start with
`cloudgateway auth login`.

SSH as `ubuntu` works only when `ssh_authorized_keys` is set and the subnet
allows port 22.

## Tear down

Each enrolled VM takes one of the region's peer slots. Free it first with
`cloudgateway down`, then `cloudgateway remove <region> <index> --yes`. Then run:

```sh
terraform destroy
```

Destroy deletes the test VM's boot volume too.
